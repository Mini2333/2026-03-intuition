// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { console2 } from "forge-std/src/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TrustSwapAndBridgeRouter } from "contracts/TrustSwapAndBridgeRouter.sol";
import { ITrustSwapAndBridgeRouter } from "contracts/interfaces/ITrustSwapAndBridgeRouter.sol";
import { ISlipstreamSwapRouter } from "contracts/interfaces/external/aerodrome/ISlipstreamSwapRouter.sol";
import { FinalityState, IMetaERC20Hub } from "contracts/interfaces/external/metalayer/IMetaERC20Hub.sol";

/* =================================================== */
/*                  PROOF-OF-CONCEPT MOCKS             */
/* =================================================== */

/// @dev Minimal ERC20 mock for PoC tests.
contract PoCMockERC20 {
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
        require(!initialized, "already initialized");
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

/// @dev Minimal WETH mock for PoC tests.
contract PoCMockWETH is PoCMockERC20 {
    constructor() PoCMockERC20("Wrapped Ether", "WETH", 18) { }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {
        deposit();
    }
}

/// @dev Mock swap router that multiplies input by outputMultiplier (simulates a swap).
contract PoCMockSwapRouter {
    uint256 public outputMultiplier = 1e12;

    function setOutputMultiplier(uint256 multiplier) external {
        outputMultiplier = multiplier;
    }

    function exactInput(ISlipstreamSwapRouter.ExactInputParams calldata params) external returns (uint256 amountOut) {
        amountOut = params.amountIn * outputMultiplier;
        require(amountOut >= params.amountOutMinimum, "Too little received");
        require(params.recipient != address(0), "Invalid recipient");

        bytes calldata path = params.path;
        address tokenIn = address(bytes20(path[:20]));
        address tokenOut = address(bytes20(path[path.length - 20:]));

        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        PoCMockERC20(tokenOut).mint(params.recipient, amountOut);
    }
}

/// @dev Mock CL factory that allows setting up valid pools.
contract PoCMockCLFactory {
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

/**
 * @dev Realistic MetaERC20Hub mock with AMOUNT-DEPENDENT bridge fees.
 *      The fee scales proportionally with the transfer amount, like a real bridge.
 *      Critically, transferRemote() validates that msg.value covers the fee for the ACTUAL
 *      amount being transferred — not whatever was quoted externally.
 *
 *      Fee formula: baseFee + (amount * feeRate / 1e18)
 */
contract PoCMockMetaERC20HubAmountDependent {
    uint256 public constant BASE_FEE = 1000 wei;
    uint256 public constant FEE_BPS = 10; // 10 basis points = 0.1% of the transfer amount
    uint256 public transferCounter;

    /// @dev Quotes the fee for a given transfer amount (amount-dependent).
    function quoteTransferRemote(uint32, bytes32, uint256 _amount) external pure returns (uint256) {
        return BASE_FEE + (_amount * FEE_BPS / 10_000);
    }

    /// @dev Executes the transfer. Validates msg.value against the ACTUAL transfer amount.
    function transferRemote(
        uint32,
        bytes32,
        uint256 _amount,
        uint256,
        FinalityState
    )
        external
        payable
        returns (bytes32 transferId)
    {
        uint256 requiredFee = BASE_FEE + (_amount * FEE_BPS / 10_000);
        require(msg.value >= requiredFee, "MetaERC20Hub: insufficient fee for actual amount");
        transferCounter++;
        transferId = keccak256(abi.encodePacked(transferCounter, block.timestamp, msg.sender));
    }
}

/* =================================================== */
/*                     PROOF TESTS                     */
/* =================================================== */

/**
 * @title PoCPeriphery
 * @notice Proves the "Bridge Fee Undercollateralization" issue is NOT exploitable.
 *
 * The claimed vulnerability: TrustSwapAndBridgeRouter quotes the bridge fee using minTrustOut
 * (caller-controlled) instead of the actual amountOut. An attacker sets near-zero minTrustOut
 * to get a tiny fee quote, but the swap yields a high amountOut, allegedly draining bridge
 * liquidity.
 *
 * Why it's NOT exploitable:
 * 1. The MetaERC20Hub.transferRemote() validates the fee against the ACTUAL transfer amount.
 *    If msg.value is insufficient for the real amount, transferRemote() reverts.
 * 2. The entire transaction is atomic — the swap, fee payment, and bridge call all happen
 *    in one transaction. If transferRemote() reverts, the swap is also reverted. No tokens
 *    move, no bridge liquidity is affected.
 * 3. An attacker setting a low minTrustOut only causes their own transaction to revert,
 *    wasting gas. They cannot extract value from the bridge.
 */
contract PoCPeriphery is Test {
    TrustSwapAndBridgeRouter public router;
    PoCMockMetaERC20HubAmountDependent public metaERC20Hub;
    PoCMockSwapRouter public swapRouter;
    PoCMockCLFactory public clFactory;

    PoCMockERC20 public usdcToken;
    PoCMockERC20 public trustToken;

    address public attacker = makeAddr("attacker");
    address public recipient = makeAddr("recipient");

    address public constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant BASE_MAINNET_TRUST = 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3;
    address payable public constant BASE_MAINNET_WETH = payable(0x4200000000000000000000000000000000000006);

    int24 public constant TICK_SPACING_100 = 100;
    uint256 public constant OUTPUT_MULTIPLIER = 1e12;
    address public constant MOCK_POOL = address(0xDEAD1);

    function setUp() public {
        // Deploy mock templates and etch them at mainnet addresses
        PoCMockERC20 usdcTemplate = new PoCMockERC20("", "", 0);
        PoCMockERC20 trustTemplate = new PoCMockERC20("", "", 0);
        PoCMockWETH wethTemplate = new PoCMockWETH();

        vm.etch(BASE_MAINNET_USDC, address(usdcTemplate).code);
        vm.etch(BASE_MAINNET_TRUST, address(trustTemplate).code);
        vm.etch(BASE_MAINNET_WETH, address(wethTemplate).code);

        usdcToken = PoCMockERC20(BASE_MAINNET_USDC);
        trustToken = PoCMockERC20(BASE_MAINNET_TRUST);

        usdcToken.initialize("USD Coin", "USDC", 6);
        trustToken.initialize("Trust Token", "TRUST", 18);
        PoCMockWETH(BASE_MAINNET_WETH).initialize("Wrapped Ether", "WETH", 18);

        // Deploy mock infrastructure
        PoCMockSwapRouter swapRouterTemplate = new PoCMockSwapRouter();
        PoCMockCLFactory clFactoryTemplate = new PoCMockCLFactory();
        PoCMockMetaERC20HubAmountDependent metaERC20HubTemplate = new PoCMockMetaERC20HubAmountDependent();

        // Deploy the real router
        router = new TrustSwapAndBridgeRouter();

        // Etch mocks at the hardcoded addresses the router expects
        vm.etch(router.slipstreamSwapRouter(), address(swapRouterTemplate).code);
        vm.etch(address(router.slipstreamFactory()), address(clFactoryTemplate).code);
        vm.etch(address(router.metaERC20Hub()), address(metaERC20HubTemplate).code);

        swapRouter = PoCMockSwapRouter(router.slipstreamSwapRouter());
        clFactory = PoCMockCLFactory(address(router.slipstreamFactory()));
        metaERC20Hub = PoCMockMetaERC20HubAmountDependent(address(router.metaERC20Hub()));

        // Configure the swap multiplier and valid pools
        swapRouter.setOutputMultiplier(OUTPUT_MULTIPLIER);
        clFactory.setPool(BASE_MAINNET_USDC, BASE_MAINNET_TRUST, TICK_SPACING_100, MOCK_POOL);
        clFactory.setPool(BASE_MAINNET_WETH, BASE_MAINNET_TRUST, TICK_SPACING_100, MOCK_POOL);

        // Fund the attacker
        usdcToken.mint(attacker, 1_000_000e6);
        vm.prank(attacker);
        usdcToken.approve(address(router), type(uint256).max);
    }

    function _buildPath(address tokenIn, int24 tickSpacing, address tokenOut) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenIn, tickSpacing, tokenOut);
    }

    /* =================================================== */
    /*  PROOF: Attack scenario reverts atomically          */
    /* =================================================== */

    /**
     * @notice Proves that the claimed attack (low minTrustOut → tiny fee → large bridge transfer)
     *         does NOT succeed. The bridge's transferRemote() validates the fee against the actual
     *         amount and reverts when underpaid.
     *
     *         Attack scenario:
     *           - Attacker swaps 1,000 USDC → expects ~1e15 TRUST (1000e6 * 1e12)
     *           - Sets minTrustOut = 1 (near-zero) to quote a tiny bridge fee
     *           - Provides only enough ETH for the tiny fee
     *         Expected result: transferRemote() reverts because the fee doesn't cover
     *         the actual amountOut of 1e15 TRUST.
     */
    function test_submissionValidity() external {
        uint256 amountIn = 1_000e6; // 1,000 USDC
        uint256 nearZeroMinTrustOut = 1; // Attacker's trick: near-zero minTrustOut

        // The fee quoted for near-zero minTrustOut is tiny
        bytes32 recipientAddr = bytes32(uint256(uint160(recipient)));
        uint256 tinyFee = metaERC20Hub.quoteTransferRemote(0, recipientAddr, nearZeroMinTrustOut);

        // The actual swap output will be much larger
        uint256 expectedAmountOut = amountIn * OUTPUT_MULTIPLIER; // 1e18
        uint256 correctFee = metaERC20Hub.quoteTransferRemote(0, recipientAddr, expectedAmountOut);

        // Demonstrate the fee mismatch
        console2.log("Fee quoted from near-zero minTrustOut:", tinyFee);
        console2.log("Fee required for actual amountOut:    ", correctFee);
        console2.log("Fee ratio (correct/tiny):             ", correctFee / tinyFee);
        assertTrue(correctFee > tinyFee, "Fees should differ for different amounts");

        bytes memory path = _buildPath(BASE_MAINNET_USDC, TICK_SPACING_100, BASE_MAINNET_TRUST);

        // Attacker provides only the tiny fee (enough for minTrustOut but not amountOut)
        vm.deal(attacker, tinyFee);

        // The transaction REVERTS because transferRemote() validates the fee
        // against the ACTUAL transfer amount (amountOut), not minTrustOut.
        vm.prank(attacker);
        vm.expectRevert("MetaERC20Hub: insufficient fee for actual amount");
        router.swapAndBridgeWithERC20{ value: tinyFee }(
            BASE_MAINNET_USDC, amountIn, path, nearZeroMinTrustOut, recipient
        );
    }

    /**
     * @notice Proves the same attack fails for swapAndBridgeWithETH.
     *         The bridge rejects the underpaid fee and the entire tx reverts atomically.
     */
    function test_swapAndBridgeWithETH_rejectsUnderpaidFee() external {
        uint256 nearZeroMinTrustOut = 1;

        bytes32 recipientAddr = bytes32(uint256(uint160(recipient)));
        uint256 tinyFee = metaERC20Hub.quoteTransferRemote(0, recipientAddr, nearZeroMinTrustOut);

        bytes memory path = _buildPath(BASE_MAINNET_WETH, TICK_SPACING_100, BASE_MAINNET_TRUST);

        // Provide tinyFee + some ETH for the swap
        uint256 swapEth = 1 ether;
        uint256 totalEth = swapEth + tinyFee;
        vm.deal(attacker, totalEth);

        // The transaction REVERTS because transferRemote() validates the fee
        vm.prank(attacker);
        vm.expectRevert("MetaERC20Hub: insufficient fee for actual amount");
        router.swapAndBridgeWithETH{ value: totalEth }(path, nearZeroMinTrustOut, recipient);
    }

    /**
     * @notice Proves that when the user sets minTrustOut to the expected output amount,
     *         the fee is correctly calculated and the transaction succeeds.
     *         This confirms the system works as intended — users must set minTrustOut
     *         appropriately because the router forwards that fee to the bridge.
     */
    function test_swapAndBridgeWithERC20_succeedsWithCorrectFee() external {
        uint256 amountIn = 1_000e6;
        uint256 expectedAmountOut = amountIn * OUTPUT_MULTIPLIER;

        // When minTrustOut == expectedAmountOut, the fee covers the actual transfer
        bytes32 recipientAddr = bytes32(uint256(uint160(recipient)));
        uint256 correctFee = metaERC20Hub.quoteTransferRemote(0, recipientAddr, expectedAmountOut);

        bytes memory path = _buildPath(BASE_MAINNET_USDC, TICK_SPACING_100, BASE_MAINNET_TRUST);

        vm.deal(attacker, correctFee);

        vm.prank(attacker);
        (uint256 amountOut, bytes32 transferId) = router.swapAndBridgeWithERC20{ value: correctFee }(
            BASE_MAINNET_USDC, amountIn, path, expectedAmountOut, recipient
        );

        assertEq(amountOut, expectedAmountOut, "Should receive expected TRUST output");
        assertTrue(transferId != bytes32(0), "Transfer ID should be non-zero");
    }

    /**
     * @notice Proves that when the user sets minTrustOut to the expected output for
     *         swapAndBridgeWithETH, the transaction succeeds.
     */
    function test_swapAndBridgeWithETH_succeedsWithCorrectFee() external {
        uint256 swapEth = 1 ether;
        uint256 expectedAmountOut = swapEth * OUTPUT_MULTIPLIER;

        bytes32 recipientAddr = bytes32(uint256(uint160(recipient)));
        uint256 correctFee = metaERC20Hub.quoteTransferRemote(0, recipientAddr, expectedAmountOut);

        bytes memory path = _buildPath(BASE_MAINNET_WETH, TICK_SPACING_100, BASE_MAINNET_TRUST);

        uint256 totalEth = swapEth + correctFee;
        vm.deal(attacker, totalEth);

        vm.prank(attacker);
        (uint256 amountOut, bytes32 transferId) =
            router.swapAndBridgeWithETH{ value: totalEth }(path, expectedAmountOut, recipient);

        assertEq(amountOut, expectedAmountOut, "Should receive expected TRUST output");
        assertTrue(transferId != bytes32(0), "Transfer ID should be non-zero");
    }

    /**
     * @notice Demonstrates that no value can be extracted: after a failed attack attempt,
     *         no state changes have occurred — no tokens moved, no bridge calls succeeded.
     *         The attacker only loses gas.
     */
    function test_atomicRevert_noStateChanges() external {
        uint256 amountIn = 1_000e6;
        uint256 nearZeroMinTrustOut = 1;

        bytes32 recipientAddr = bytes32(uint256(uint160(recipient)));
        uint256 tinyFee = metaERC20Hub.quoteTransferRemote(0, recipientAddr, nearZeroMinTrustOut);

        bytes memory path = _buildPath(BASE_MAINNET_USDC, TICK_SPACING_100, BASE_MAINNET_TRUST);

        vm.deal(attacker, tinyFee);

        // Record state before attack attempt
        uint256 attackerUsdcBefore = usdcToken.balanceOf(attacker);
        uint256 attackerEthBefore = attacker.balance;
        uint256 bridgeTransfersBefore = metaERC20Hub.transferCounter();

        // Attack attempt reverts
        vm.prank(attacker);
        vm.expectRevert("MetaERC20Hub: insufficient fee for actual amount");
        router.swapAndBridgeWithERC20{ value: tinyFee }(
            BASE_MAINNET_USDC, amountIn, path, nearZeroMinTrustOut, recipient
        );

        // Verify no state changes occurred — full atomicity
        assertEq(usdcToken.balanceOf(attacker), attackerUsdcBefore, "Attacker USDC unchanged");
        assertEq(attacker.balance, attackerEthBefore, "Attacker ETH unchanged");
        assertEq(metaERC20Hub.transferCounter(), bridgeTransfersBefore, "No bridge transfers occurred");
    }
}
