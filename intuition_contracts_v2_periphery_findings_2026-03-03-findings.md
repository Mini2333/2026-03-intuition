# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.

`Note: Not all issues are guaranteed to be correct.`
---

# Bridge fee quoted from slippage minimum
- Severity: High

## Targets
- swapAndBridgeWithERC20 (TrustSwapAndBridgeRouter)
- swapAndBridgeWithETH (TrustSwapAndBridgeRouter)

## Affected Locations
- **TrustSwapAndBridgeRouter.swapAndBridgeWithERC20**: This function calls `quoteTransferRemote` using the caller-controlled `minTrustOut` and then later calls `_bridgeTrust` with the actual swap output `amountOut` without recomputing/adjusting the fee, so the bridged amount and paid fee can diverge; fixing the fee computation here (or recomputing after the swap) removes the underfunding/revert risk.
- **TrustSwapAndBridgeRouter.swapAndBridgeWithETH**: This function similarly derives `bridgeFee` from `minTrustOut` before the swap but bridges the post-swap `amountOut`, enabling callers to select a low minimum to minimize fees while still bridging more; changing this logic to base the fee on `amountOut` (or requiring `amountOut == minTrustOut`) remediates the mismatch.

## Description

`swapAndBridgeWithERC20` and `swapAndBridgeWithETH` compute the bridge fee by calling `quoteTransferRemote` using the caller-supplied `minTrustOut` before performing the swap. The swap can return an `amountOut` that is higher than this minimum, but the router then bridges the full `amountOut` while still forwarding the fee that was quoted for `minTrustOut`. Because `minTrustOut` is a user-controlled lower bound, callers can deliberately set it very low to reduce the quoted fee without proportionally reducing the actual amount they end up bridging. If the hub/relayer fee model scales with the bridged amount (as implied by quoting by amount), the forwarded fee is inconsistent with the bridged value. This can either make the bridge submission underfunded (subsidized by the system/relayers) or cause the bridge call to revert after the swap, breaking the swap-and-bridge flow under normal slippage settings.

## Root cause

The router quotes/uses a bridge fee derived from `minTrustOut` but bridges `amountOut`, so the fee is based on a caller-controlled minimum rather than the actual bridged amount.

## Impact

A caller can underpay bridge fees by choosing an artificially low `minTrustOut` while still producing and bridging a much larger `amountOut`. If the bridge hub validates fee sufficiency, transactions can revert after the swap, causing unreliable behavior and potential loss of gas or failed integrations. If fee sufficiency is not strictly enforced, the protocol/relayers may absorb costs or transfers may become delayed/stuck due to underfunding.

## Triage Summary (Plain Language)

- **Is this a real issue?** Yes. Fee quoting is tied to a user-provided minimum (`minTrustOut`) instead of the actual bridged amount (`amountOut`), so fee and bridged value can diverge.
- **Should this be feared as a critical drain?** Usually not a direct vault-drain bug, but it is still important: it can cause failed swap+bridge transactions, broken UX/integrations, and potential relayer/protocol fee shortfalls.
- **Can an attacker always get away with low fees?** Not always. If the bridge hub/relayer enforces required fees, the transaction should revert (attacker only wastes gas). If enforcement is weak or subsidized, underpayment can succeed and costs are externalized.

## Proof of Concept

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { Test } from "forge-std/src/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TrustSwapAndBridgeRouter } from "contracts/TrustSwapAndBridgeRouter.sol";
import { ISlipstreamSwapRouter } from "contracts/interfaces/external/aerodrome/ISlipstreamSwapRouter.sol";
import { FinalityState } from "contracts/interfaces/external/metalayer/IMetaERC20Hub.sol";

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
        require(amountOut >= params.amountOutMinimum, "Too little received");

        bytes calldata path = params.path;
        address tokenIn = address(bytes20(path[:20]));
        address tokenOut = address(bytes20(path[path.length - 20:]));

        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        MockERC20(tokenOut).mint(params.recipient, amountOut);
    }
}

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

contract MockMetaERC20HubFeeByAmount {
    uint256 public constant FEE_DIVISOR = 1e9;
    uint256 public lastAmount;
    uint256 public lastFee;

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
        lastAmount = amount;
        lastFee = msg.value;
        transferId = keccak256(abi.encodePacked(amount, msg.value, block.timestamp));
    }
}

contract TrustSwapAndBridgeRouterFeeBugTest is Test {
    TrustSwapAndBridgeRouter public router;
    MockMetaERC20HubFeeByAmount public metaHub;

    MockERC20 public usdcToken;
    MockERC20 public trustToken;

    address public user = makeAddr("user");

    address public constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant BASE_MAINNET_TRUST = 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3;
    address payable public constant BASE_MAINNET_WETH = payable(0x4200000000000000000000000000000000000006);

    int24 public constant TICK_SPACING_100 = 100;

    uint256 public constant OUTPUT_MULTIPLIER = 1e12;

    function setUp() public {
        MockERC20 usdcTemplate = new MockERC20("", "", 0);
        MockERC20 trustTemplate = new MockERC20("", "", 0);
        MockWETH wethTemplate = new MockWETH();

        vm.etch(BASE_MAINNET_USDC, address(usdcTemplate).code);
        vm.etch(BASE_MAINNET_TRUST, address(trustTemplate).code);
        vm.etch(BASE_MAINNET_WETH, address(wethTemplate).code);

        usdcToken = MockERC20(BASE_MAINNET_USDC);
        trustToken = MockERC20(BASE_MAINNET_TRUST);

        usdcToken.initialize("USD Coin", "USDC", 6);
        trustToken.initialize("Trust Token", "TRUST", 18);
        MockWETH(BASE_MAINNET_WETH).initialize("Wrapped Ether", "WETH", 18);

        router = new TrustSwapAndBridgeRouter();

        MockSlipstreamSwapRouter swapRouterTemplate = new MockSlipstreamSwapRouter(OUTPUT_MULTIPLIER);
        MockCLFactory clFactoryTemplate = new MockCLFactory();
        MockMetaERC20HubFeeByAmount metaTemplate = new MockMetaERC20HubFeeByAmount();

        vm.etch(router.slipstreamSwapRouter(), address(swapRouterTemplate).code);
        vm.etch(address(router.slipstreamFactory()), address(clFactoryTemplate).code);
        vm.etch(address(router.metaERC20Hub()), address(metaTemplate).code);

        MockSlipstreamSwapRouter swapRouter = MockSlipstreamSwapRouter(router.slipstreamSwapRouter());
        swapRouter.setOutputMultiplier(OUTPUT_MULTIPLIER);

        MockCLFactory clFactory = MockCLFactory(address(router.slipstreamFactory()));
        clFactory.setPool(BASE_MAINNET_USDC, BASE_MAINNET_TRUST, TICK_SPACING_100, address(0xBEEF));

        metaHub = MockMetaERC20HubFeeByAmount(address(router.metaERC20Hub()));

        usdcToken.mint(user, 10_000e6);
        vm.prank(user);
        usdcToken.approve(address(router), type(uint256).max);
    }

    function test_feeQuotedFromMinTrustOutUndercollateralizesBridge() public {
        uint256 amountIn = 1e6; // 1 USDC
        uint256 expectedAmountOut = amountIn * OUTPUT_MULTIPLIER; // 1e18 TRUST
        uint256 minTrustOut = 1e12; // far below expected output

        bytes memory path = abi.encodePacked(BASE_MAINNET_USDC, TICK_SPACING_100, BASE_MAINNET_TRUST);

        uint256 quotedFee = metaHub.quoteTransferRemote(
            router.recipientDomain(), bytes32(uint256(uint160(user))), minTrustOut
        );

        vm.deal(user, quotedFee);

        vm.prank(user);
        (uint256 amountOut,) = router.swapAndBridgeWithERC20{ value: quotedFee }(
            BASE_MAINNET_USDC, amountIn, path, minTrustOut, user
        );

        assertEq(amountOut, expectedAmountOut);
        assertEq(metaHub.lastAmount(), expectedAmountOut);
        assertEq(metaHub.lastFee(), quotedFee);

        uint256 expectedFeeForAmountOut = expectedAmountOut / metaHub.FEE_DIVISOR();
        assertGt(expectedFeeForAmountOut, quotedFee, "Fee paid should be lower than fee for actual amount");
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Quote the bridge fee using the actual `amountOut` so the forwarded fee scales with the bridged amount, and reserve ETH for the fee in `swapAndBridgeWithETH` by estimating output via the Slipstream quoter, then refund any overage after recomputing the exact fee post-swap.

### Patch

```diff
diff --git a/intuition-contracts-v2-periphery/contracts/TrustSwapAndBridgeRouter.sol b/intuition-contracts-v2-periphery/contracts/TrustSwapAndBridgeRouter.sol
--- a/intuition-contracts-v2-periphery/contracts/TrustSwapAndBridgeRouter.sol
+++ b/intuition-contracts-v2-periphery/contracts/TrustSwapAndBridgeRouter.sol
@@ -91,7 +91,9 @@
 
         bytes32 recipientAddress = _formatRecipientAddress(recipient);
 
-        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, minTrustOut);
+        (uint256 quotedAmountOut,,,) = ICLQuoter(slipstreamQuoter).quoteExactInput(path, msg.value);
+
+        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, quotedAmountOut);
         if (msg.value <= bridgeFee) {
             revert TrustSwapAndBridgeRouter_InsufficientETH();
         }
@@ -113,7 +115,15 @@
                 })
             );
 
-        transferId = _bridgeTrust(amountOut, recipientAddress, bridgeFee);
+        uint256 actualBridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, amountOut);
+        if (actualBridgeFee > bridgeFee) {
+            revert TrustSwapAndBridgeRouter_InsufficientETH();
+        }
+
+        transferId = _bridgeTrust(amountOut, recipientAddress, actualBridgeFee);
+
+        uint256 refundAmount = bridgeFee - actualBridgeFee;
+        _refundExcess(refundAmount);
 
         emit SwappedAndBridgedFromETH(msg.sender, swapEth, amountOut, recipientAddress, transferId);
     }
diff --git a/intuition-contracts-v2-periphery/contracts/TrustSwapAndBridgeRouter.sol b/intuition-contracts-v2-periphery/contracts/TrustSwapAndBridgeRouter.sol
--- a/intuition-contracts-v2-periphery/contracts/TrustSwapAndBridgeRouter.sol
+++ b/intuition-contracts-v2-periphery/contracts/TrustSwapAndBridgeRouter.sol
@@ -149,11 +149,6 @@
 
         bytes32 recipientAddress = _formatRecipientAddress(recipient);
 
-        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, minTrustOut);
-        if (msg.value < bridgeFee) {
-            revert TrustSwapAndBridgeRouter_InsufficientBridgeFee();
-        }
-
         IERC20(tokenIn).safeIncreaseAllowance(slipstreamSwapRouter, amountIn);
 
         amountOut = ISlipstreamSwapRouter(slipstreamSwapRouter)
@@ -167,6 +162,11 @@
                 })
             );
 
+        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, amountOut);
+        if (msg.value < bridgeFee) {
+            revert TrustSwapAndBridgeRouter_InsufficientBridgeFee();
+        }
+
         transferId = _bridgeTrust(amountOut, recipientAddress, bridgeFee);
 
         uint256 refundAmount = msg.value - bridgeFee;
```

### Affected Files

- `intuition-contracts-v2-periphery/contracts/TrustSwapAndBridgeRouter.sol`

### Validation Output

```
Compiling 21 files with Solc 0.8.29
Solc 0.8.29 finished in 4.90s
Compiler run successful!

Ran 1 test for tests/TrustSwapAndBridgeRouter.t.sol:TrustSwapAndBridgeRouterFeeBugTest
[FAIL: TrustSwapAndBridgeRouter_InsufficientBridgeFee()] test_feeQuotedFromMinTrustOutUndercollateralizesBridge() (gas: 174729)
Traces:
  [4508535] TrustSwapAndBridgeRouterFeeBugTest::setUp()
    ├─ [586583] → new MockERC20@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   └─ ← [Return] 2889 bytes of code
    ├─ [586583] → new MockERC20@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   └─ ← [Return] 2889 bytes of code
    ├─ [662556] → new MockWETH@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   └─ ← [Return] 2974 bytes of code
    ├─ [0] VM::etch(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 0x60806040526004361015610011575f80fd5b5f3560e01c806306fdde03146108bf578063095ea7b31461086a578063158ef93e146108485780631624f6c6146103ca57806318160ddd146103ad57806323b872dd14610336578063313ce5671461031657806340c10f19146102bb57806370a082311461027657806395d89b411461017e578063a9059cbb1461010f5763dd62ed3e1461009d575f80fd5b3461010b57604060031936011261010b576100b6610a3b565b73ffffffffffffffffffffffffffffffffffffffff6100d3610a5e565b91165f52600660205273ffffffffffffffffffffffffffffffffffffffff60405f2091165f52602052602060405f2054604051908152f35b5f80fd5b3461010b57604060031936011261010b57610128610a3b565b73ffffffffffffffffffffffffffffffffffffffff60243591335f52600560205260405f20610158848254610af5565b9055165f52600560205261017160405f20918254610b2f565b9055602060405160018152f35b3461010b575f60031936011261010b576040515f60015461019e81610961565b808452906001811690811561023457506001146101d6575b6101d2836101c6818503826109b2565b604051918291826109f3565b0390f35b60015f9081527fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6939250905b80821061021a575090915081016020016101c66101b6565b919260018160209254838588010152019101909291610202565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff001660208086019190915291151560051b840190910191506101c690506101b6565b3461010b57602060031936011261010b5773ffffffffffffffffffffffffffffffffffffffff6102a4610a3b565b165f526005602052602060405f2054604051908152f35b3461010b57604060031936011261010b576103116102d7610a3b565b73ffffffffffffffffffffffffffffffffffffffff60243591165f52600560205260405f20610307828254610b2f565b9055600354610b2f565b600355005b3461010b575f60031936011261010b57602060ff60025416604051908152f35b3461010b57606060031936011261010b5761034f610a3b565b73ffffffffffffffffffffffffffffffffffffffff61036c610a5e565b816044359316805f52600660205260405f208333165f5260205260405f20610395858254610af5565b90555f52600560205260405f20610158848254610af5565b3461010b575f60031936011261010b576020600354604051908152f35b3461010b57606060031936011261010b5760043567ffffffffffffffff811161010b576103fb903690600401610a81565b60243567ffffffffffffffff811161010b5761041b903690600401610a81565b60443560ff811680910361010b5760045460ff81166107ea577fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0016600117600455825167ffffffffffffffff8111610675576104775f54610961565b601f811161074a575b506020601f82116001146106ad57819293945f926106a2575b50505f198260011b9260031b1c1916175f555b815167ffffffffffffffff8111610675576104c8600154610961565b601f81116105d4575b50602092601f821160011461053757928192935f9261052c575b50505f198260011b9260031b1c1916176001555b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0060025416176002555f80f35b0151905083806104eb565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe082169360015f527fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6915f5b8681106105bc57508360019596106105a4575b505050811b016001556104ff565b01515f1960f88460031b161c19169055838080610596565b91926020600181928685015181550194019201610583565b60015f52601f820160051c7fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf601906020831061064d575b601f0160051c7fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf601905b81811061064257506104d1565b5f8155600101610635565b7fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6915061060b565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52604160045260245ffd5b015190508480610499565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe08216905f80527f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563915f5b8181106107325750958360019596971061071a575b505050811b015f556104ac565b01515f1960f88460031b161c1916905584808061070d565b9192602060018192868b0151815501940192016106f8565b5f8052601f820160051c7f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e5630190602083106107c2575b601f0160051c7f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e56301905b8181106107b75750610480565b5f81556001016107aa565b7f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e5639150610780565b60646040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601e60248201527f4d6f636b45524332303a20616c726561647920696e697469616c697a656400006044820152fd5b3461010b575f60031936011261010b57602060ff600454166040519015158152f35b3461010b57604060031936011261010b57610883610a3b565b335f52600660205273ffffffffffffffffffffffffffffffffffffffff60405f2091165f5260205260405f206024359055602060405160018152f35b3461010b575f60031936011261010b576040515f5f546108de81610961565b80845290600181169081156102345750600114610905576101d2836101c6818503826109b2565b5f8080527f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563939250905b808210610947575090915081016020016101c66101b6565b91926001816020925483858801015201910190929161092f565b90600182811c921680156109a8575b602083101461097b57565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52602260045260245ffd5b91607f1691610970565b90601f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0910116810190811067ffffffffffffffff82111761067557604052565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f602060409481855280519182918282880152018686015e5f8582860101520116010190565b6004359073ffffffffffffffffffffffffffffffffffffffff8216820361010b57565b6024359073ffffffffffffffffffffffffffffffffffffffff8216820361010b57565b81601f8201121561010b5780359067ffffffffffffffff82116106755760405192610ad460207fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f86011601856109b2565b8284526020838301011161010b57815f926020809301838601378301015290565b91908203918211610b0257565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b91908201809211610b025756fea164736f6c634300081d000a)
    │   └─ ← [Return]
    ├─ [0] VM::etch(0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3, 0x60806040526004361015610011575f80fd5b5f3560e01c806306fdde03146108bf578063095ea7b31461086a578063158ef93e146108485780631624f6c6146103ca57806318160ddd146103ad57806323b872dd14610336578063313ce5671461031657806340c10f19146102bb57806370a082311461027657806395d89b411461017e578063a9059cbb1461010f5763dd62ed3e1461009d575f80fd5b3461010b57604060031936011261010b576100b6610a3b565b73ffffffffffffffffffffffffffffffffffffffff6100d3610a5e565b91165f52600660205273ffffffffffffffffffffffffffffffffffffffff60405f2091165f52602052602060405f2054604051908152f35b5f80fd5b3461010b57604060031936011261010b57610128610a3b565b73ffffffffffffffffffffffffffffffffffffffff60243591335f52600560205260405f20610158848254610af5565b9055165f52600560205261017160405f20918254610b2f565b9055602060405160018152f35b3461010b575f60031936011261010b576040515f60015461019e81610961565b808452906001811690811561023457506001146101d6575b6101d2836101c6818503826109b2565b604051918291826109f3565b0390f35b60015f9081527fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6939250905b80821061021a575090915081016020016101c66101b6565b919260018160209254838588010152019101909291610202565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff001660208086019190915291151560051b840190910191506101c690506101b6565b3461010b57602060031936011261010b5773ffffffffffffffffffffffffffffffffffffffff6102a4610a3b565b165f526005602052602060405f2054604051908152f35b3461010b57604060031936011261010b576103116102d7610a3b565b73ffffffffffffffffffffffffffffffffffffffff60243591165f52600560205260405f20610307828254610b2f565b9055600354610b2f565b600355005b3461010b575f60031936011261010b57602060ff60025416604051908152f35b3461010b57606060031936011261010b5761034f610a3b565b73ffffffffffffffffffffffffffffffffffffffff61036c610a5e565b816044359316805f52600660205260405f208333165f5260205260405f20610395858254610af5565b90555f52600560205260405f20610158848254610af5565b3461010b575f60031936011261010b576020600354604051908152f35b3461010b57606060031936011261010b5760043567ffffffffffffffff811161010b576103fb903690600401610a81565b60243567ffffffffffffffff811161010b5761041b903690600401610a81565b60443560ff811680910361010b5760045460ff81166107ea577fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0016600117600455825167ffffffffffffffff8111610675576104775f54610961565b601f811161074a575b506020601f82116001146106ad57819293945f926106a2575b50505f198260011b9260031b1c1916175f555b815167ffffffffffffffff8111610675576104c8600154610961565b601f81116105d4575b50602092601f821160011461053757928192935f9261052c575b50505f198260011b9260031b1c1916176001555b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0060025416176002555f80f35b0151905083806104eb565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe082169360015f527fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6915f5b8681106105bc57508360019596106105a4575b505050811b016001556104ff565b01515f1960f88460031b161c19169055838080610596565b91926020600181928685015181550194019201610583565b60015f52601f820160051c7fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf601906020831061064d575b601f0160051c7fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf601905b81811061064257506104d1565b5f8155600101610635565b7fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6915061060b565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52604160045260245ffd5b015190508480610499565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe08216905f80527f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563915f5b8181106107325750958360019596971061071a575b505050811b015f556104ac565b01515f1960f88460031b161c1916905584808061070d565b9192602060018192868b0151815501940192016106f8565b5f8052601f820160051c7f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e5630190602083106107c2575b601f0160051c7f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e56301905b8181106107b75750610480565b5f81556001016107aa565b7f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e5639150610780565b60646040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601e60248201527f4d6f636b45524332303a20616c726561647920696e697469616c697a656400006044820152fd5b3461010b575f60031936011261010b57602060ff600454166040519015158152f35b3461010b57604060031936011261010b57610883610a3b565b335f52600660205273ffffffffffffffffffffffffffffffffffffffff60405f2091165f5260205260405f206024359055602060405160018152f35b3461010b575f60031936011261010b576040515f5f546108de81610961565b80845290600181169081156102345750600114610905576101d2836101c6818503826109b2565b5f8080527f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563939250905b808210610947575090915081016020016101c66101b6565b91926001816020925483858801015201910190929161092f565b90600182811c921680156109a8575b602083101461097b57565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52602260045260245ffd5b91607f1691610970565b90601f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0910116810190811067ffffffffffffffff82111761067557604052565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f602060409481855280519182918282880152018686015e5f8582860101520116010190565b6004359073ffffffffffffffffffffffffffffffffffffffff8216820361010b57565b6024359073ffffffffffffffffffffffffffffffffffffffff8216820361010b57565b81601f8201121561010b5780359067ffffffffffffffff82116106755760405192610ad460207fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f86011601856109b2565b8284526020838301011161010b57815f926020809301838601378301015290565b91908203918211610b0257565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b91908201809211610b025756fea164736f6c634300081d000a)
    │   └─ ← [Return]
    ├─ [0] VM::etch(0x4200000000000000000000000000000000000006, 0x60806040526004361015610022575b3615610018575f80fd5b610020610b67565b005b5f3560e01c806306fdde03146108ea578063095ea7b314610895578063158ef93e146108735780631624f6c6146103f557806318160ddd146103d857806323b872dd14610361578063313ce5671461034157806340c10f19146102e657806370a08231146102a157806395d89b41146101a9578063a9059cbb1461013a578063d0e30db0146101275763dd62ed3e0361000e5734610123576040600319360112610123576100ce610a66565b73ffffffffffffffffffffffffffffffffffffffff6100eb610a89565b91165f52600660205273ffffffffffffffffffffffffffffffffffffffff60405f2091165f52602052602060405f2054604051908152f35b5f80fd5b5f60031936011261012357610020610b67565b3461012357604060031936011261012357610153610a66565b73ffffffffffffffffffffffffffffffffffffffff60243591335f52600560205260405f20610183848254610b20565b9055165f52600560205261019c60405f20918254610b5a565b9055602060405160018152f35b34610123575f600319360112610123576040515f6001546101c98161098c565b808452906001811690811561025f5750600114610201575b6101fd836101f1818503826109dd565b60405191829182610a1e565b0390f35b60015f9081527fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6939250905b808210610245575090915081016020016101f16101e1565b91926001816020925483858801015201910190929161022d565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff001660208086019190915291151560051b840190910191506101f190506101e1565b346101235760206003193601126101235773ffffffffffffffffffffffffffffffffffffffff6102cf610a66565b165f526005602052602060405f2054604051908152f35b346101235760406003193601126101235761033c610302610a66565b73ffffffffffffffffffffffffffffffffffffffff60243591165f52600560205260405f20610332828254610b5a565b9055600354610b5a565b600355005b34610123575f60031936011261012357602060ff60025416604051908152f35b346101235760606003193601126101235761037a610a66565b73ffffffffffffffffffffffffffffffffffffffff610397610a89565b816044359316805f52600660205260405f208333165f5260205260405f206103c0858254610b20565b90555f52600560205260405f20610183848254610b20565b34610123575f600319360112610123576020600354604051908152f35b346101235760606003193601126101235760043567ffffffffffffffff811161012357610426903690600401610aac565b60243567ffffffffffffffff811161012357610446903690600401610aac565b60443560ff81168091036101235760045460ff8116610815577fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0016600117600455825167ffffffffffffffff81116106a0576104a25f5461098c565b601f8111610775575b506020601f82116001146106d857819293945f926106cd575b50505f198260011b9260031b1c1916175f555b815167ffffffffffffffff81116106a0576104f360015461098c565b601f81116105ff575b50602092601f821160011461056257928192935f92610557575b50505f198260011b9260031b1c1916176001555b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0060025416176002555f80f35b015190508380610516565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe082169360015f527fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6915f5b8681106105e757508360019596106105cf575b505050811b0160015561052a565b01515f1960f88460031b161c191690558380806105c1565b919260206001819286850151815501940192016105ae565b60015f52601f820160051c7fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6019060208310610678575b601f0160051c7fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf601905b81811061066d57506104fc565b5f8155600101610660565b7fb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf69150610636565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52604160045260245ffd5b0151905084806104c4565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe08216905f80527f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563915f5b81811061075d57509583600195969710610745575b505050811b015f556104d7565b01515f1960f88460031b161c19169055848080610738565b9192602060018192868b015181550194019201610723565b5f8052601f820160051c7f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e5630190602083106107ed575b601f0160051c7f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e56301905b8181106107e257506104ab565b5f81556001016107d5565b7f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e56391506107ab565b60646040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601e60248201527f4d6f636b45524332303a20616c726561647920696e697469616c697a656400006044820152fd5b34610123575f60031936011261012357602060ff600454166040519015158152f35b34610123576040600319360112610123576108ae610a66565b335f52600660205273ffffffffffffffffffffffffffffffffffffffff60405f2091165f5260205260405f206024359055602060405160018152f35b34610123575f600319360112610123576040515f5f546109098161098c565b808452906001811690811561025f5750600114610930576101fd836101f1818503826109dd565b5f8080527f290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563939250905b808210610972575090915081016020016101f16101e1565b91926001816020925483858801015201910190929161095a565b90600182811c921680156109d3575b60208310146109a657565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52602260045260245ffd5b91607f169161099b565b90601f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0910116810190811067ffffffffffffffff8211176106a057604052565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f602060409481855280519182918282880152018686015e5f8582860101520116010190565b6004359073ffffffffffffffffffffffffffffffffffffffff8216820361012357565b6024359073ffffffffffffffffffffffffffffffffffffffff8216820361012357565b81601f820112156101235780359067ffffffffffffffff82116106a05760405192610aff60207fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f86011601856109dd565b8284526020838301011161012357815f926020809301838601378301015290565b91908203918211610b2d57565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b91908201809211610b2d57565b335f52600560205260405f20610b7e348254610b5a565b9055610b8c34600354610b5a565b60035556fea164736f6c634300081d000a)
    │   └─ ← [Return]
    ├─ [89990] 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913::initialize("USD Coin", "USDC", 6)
    │   └─ ← [Return]
    ├─ [89990] 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3::initialize("Trust Token", "TRUST", 18)
    │   └─ ← [Return]
    ├─ [89990] 0x4200000000000000000000000000000000000006::initialize("Wrapped Ether", "WETH", 18)
    │   └─ ← [Return]
    ├─ [1476428] → new TrustSwapAndBridgeRouter@0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
    │   └─ ← [Return] 7264 bytes of code
    ├─ [246926] → new MockSlipstreamSwapRouter@0xc7183455a4C133Ae270771860664b6B7ec320bB1
    │   └─ ← [Return] 1122 bytes of code
    ├─ [133384] → new MockCLFactory@0xa0Cb889707d426A7A386870A03bc70d1b0697598
    │   └─ ← [Return] 666 bytes of code
    ├─ [109765] → new MockMetaERC20HubFeeByAmount@0x1d1499e622D69689cdf9004d05Ec547d650Ff211
    │   └─ ← [Return] 548 bytes of code
    ├─ [153] TrustSwapAndBridgeRouter::slipstreamSwapRouter() [staticcall]
    │   └─ ← [Return] 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D
    ├─ [0] VM::etch(0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D, 0x6080806040526004361015610012575f80fd5b5f905f3560e01c90816318df36f6146103b1578163c04b8d591461007c575063e265ae451461003f575f80fd5b3461007957807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126100795760209054604051908152f35b80fd5b346102e75760207ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126102e7576004359067ffffffffffffffff82116102e7578136039160a07ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc8401126102e7576064810135925f5492838502938585041485151715610328576084830135841061035557507fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdd826004013591018112156102e757810160048101359067ffffffffffffffff82116102e7576024810182360381136102e757826014116102e75735827fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffec8101116103285760647fffffffffffffffffffffffffffffffffffffffff00000000000000000000000060247fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffec73ffffffffffffffffffffffffffffffffffffffff96602096010101351660601c965f60405195869485937f23b872dd000000000000000000000000000000000000000000000000000000008552336004860152306024860152604485015260601c165af180156102dc576102eb575b506024013573ffffffffffffffffffffffffffffffffffffffff81168091036102e757823b156102e7575f926044849260405195869384927f40c10f1900000000000000000000000000000000000000000000000000000000845260048401528660248401525af19182156102dc576020926102cc575b50604051908152f35b5f6102d6916103e7565b5f6102c3565b6040513d5f823e3d90fd5b5f80fd5b6020813d602011610320575b81610304602093836103e7565b810103126102e757519081151582036102e7579050602461024c565b3d91506102f7565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b807f08c379a0000000000000000000000000000000000000000000000000000000006064925260206004820152601360248201527f546f6f206c6974746c65207265636569766564000000000000000000000000006044820152fd5b346102e75760207ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126102e7576004355f55005b90601f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0910116810190811067ffffffffffffffff82111761042857604052565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52604160045260245ffdfea164736f6c634300081d000a)
    │   └─ ← [Return]
    ├─ [315] TrustSwapAndBridgeRouter::slipstreamFactory() [staticcall]
    │   └─ ← [Return] 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a
    ├─ [0] VM::etch(0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a, 0x60806040526004361015610011575f80fd5b5f3560e01c806328af8d0b146100dc57636f3be0181461002f575f80fd5b346100d85760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126100d85761006661014c565b61006e61016f565b90610077610192565b6064359273ffffffffffffffffffffffffffffffffffffffff84168094036100d8576100a29261020b565b5f525f60205260405f20907fffffffffffffffffffffffff00000000000000000000000000000000000000008254161790555f80f35b5f80fd5b346100d85760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126100d857602061012e61011861014c565b61012061016f565b610128610192565b916101a2565b73ffffffffffffffffffffffffffffffffffffffff60405191168152f35b6004359073ffffffffffffffffffffffffffffffffffffffff821682036100d857565b6024359073ffffffffffffffffffffffffffffffffffffffff821682036100d857565b604435908160020b82036100d857565b9190916101b082848361020b565b5f525f60205273ffffffffffffffffffffffffffffffffffffffff60405f2054169283610205576101e1935061020b565b5f525f60205273ffffffffffffffffffffffffffffffffffffffff60405f20541690565b50505090565b9173ffffffffffffffffffffffffffffffffffffffff6040519281602085019516855216604083015260020b6060820152606081526080810181811067ffffffffffffffff8211176102605760405251902090565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52604160045260245ffdfea164736f6c634300081d000a)
    │   └─ ← [Return]
    ├─ [246] TrustSwapAndBridgeRouter::metaERC20Hub() [staticcall]
    │   └─ ← [Return] 0xE12aaF1529Ae21899029a9b51cca2F2Bc2cfC421
    ├─ [0] VM::etch(0xE12aaF1529Ae21899029a9b51cca2F2Bc2cfC421, 0x6080806040526004361015610012575f80fd5b5f3560e01c90816310a7265c1461015257508063829a86d9146101185780638bd90b82146100ce5780639801134e1461009357639e93ad8e14610053575f80fd5b3461008f575f7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261008f576020604051633b9aca008152f35b5f80fd5b3461008f575f7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261008f576020600154604051908152f35b3461008f5760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261008f57610105610204565b506020604051633b9aca00604435048152f35b3461008f575f7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261008f5760205f54604051908152f35b60a07ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261008f57610184610204565b506044356003608435101561008f57805f55346001556020820190815234604083015242606083015260608252608082019082821067ffffffffffffffff8311176101d757602092826040525190208152f35b7f4e487b71000000000000000000000000000000000000000000000000000000005f52604160045260245ffd5b6004359063ffffffff8216820361008f5756fea164736f6c634300081d000a)
    │   └─ ← [Return]
    ├─ [153] TrustSwapAndBridgeRouter::slipstreamSwapRouter() [staticcall]
    │   └─ ← [Return] 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D
    ├─ [22238] 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D::setOutputMultiplier(1000000000000 [1e12])
    │   └─ ← [Stop]
    ├─ [315] TrustSwapAndBridgeRouter::slipstreamFactory() [staticcall]
    │   └─ ← [Return] 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a
    ├─ [22780] 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a::setPool(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3, 100, 0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [246] TrustSwapAndBridgeRouter::metaERC20Hub() [staticcall]
    │   └─ ← [Return] 0xE12aaF1529Ae21899029a9b51cca2F2Bc2cfC421
    ├─ [44744] 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913::mint(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], 10000000000 [1e10])
    │   └─ ← [Stop]
    ├─ [0] VM::prank(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D])
    │   └─ ← [Return]
    ├─ [22468] 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913::approve(TrustSwapAndBridgeRouter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    └─ ← [Return]

  [174729] TrustSwapAndBridgeRouterFeeBugTest::test_feeQuotedFromMinTrustOutUndercollateralizesBridge()
    ├─ [337] TrustSwapAndBridgeRouter::recipientDomain() [staticcall]
    │   └─ ← [Return] 1155
    ├─ [269] 0xE12aaF1529Ae21899029a9b51cca2F2Bc2cfC421::quoteTransferRemote(1155, 0x0000000000000000000000006ca6d1e2d5347bfab1d91e883f1915560e09129d, 1000000000000 [1e12]) [staticcall]
    │   └─ ← [Return] 1000
    ├─ [0] VM::deal(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], 1000)
    │   └─ ← [Return]
    ├─ [0] VM::prank(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D])
    │   └─ ← [Return]
    ├─ [150587] TrustSwapAndBridgeRouter::swapAndBridgeWithERC20{value: 1000}(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 1000000 [1e6], 0x833589fcd6edb6e08f4c7c32d4f71b54bda029130000646cd905df2ed214b22e0d48ff17cd4200c1c6d8a3, 1000000000000 [1e12], user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D])
    │   ├─ [2799] 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a::getPool(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3, 100) [staticcall]
    │   │   └─ ← [Return] 0x000000000000000000000000000000000000bEEF
    │   ├─ [32952] 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913::transferFrom(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], TrustSwapAndBridgeRouter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9], 1000000 [1e6])
    │   │   └─ ← [Return] true
    │   ├─ [2744] 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913::allowance(TrustSwapAndBridgeRouter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9], 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D) [staticcall]
    │   │   └─ ← [Return] 0
    │   ├─ [20368] 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913::approve(0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D, 1000000 [1e6])
    │   │   └─ ← [Return] true
    │   ├─ [74185] 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D::exactInput(ExactInputParams({ path: 0x833589fcd6edb6e08f4c7c32d4f71b54bda029130000646cd905df2ed214b22e0d48ff17cd4200c1c6d8a3, recipient: 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, deadline: 1, amountIn: 1000000 [1e6], amountOutMinimum: 1000000000000 [1e12] }))
    │   │   ├─ [23352] 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913::transferFrom(TrustSwapAndBridgeRouter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9], 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D, 1000000 [1e6])
    │   │   │   └─ ← [Return] true
    │   │   ├─ [44744] 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3::mint(TrustSwapAndBridgeRouter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9], 1000000000000000000 [1e18])
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Return] 1000000000000000000 [1e18]
    │   ├─ [269] 0xE12aaF1529Ae21899029a9b51cca2F2Bc2cfC421::quoteTransferRemote(1155, 0x0000000000000000000000006ca6d1e2d5347bfab1d91e883f1915560e09129d, 1000000000000000000 [1e18]) [staticcall]
    │   │   └─ ← [Return] 1000000000 [1e9]
    │   └─ ← [Revert] TrustSwapAndBridgeRouter_InsufficientBridgeFee()
    └─ ← [Revert] TrustSwapAndBridgeRouter_InsufficientBridgeFee()

Backtrace:
  at TrustSwapAndBridgeRouter.swapAndBridgeWithERC20
  at TrustSwapAndBridgeRouterFeeBugTest.test_feeQuotedFromMinTrustOutUndercollateralizesBridge

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 1.86ms (260.70µs CPU time)

Ran 1 test suite in 26.79ms (1.86ms CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in tests/TrustSwapAndBridgeRouter.t.sol:TrustSwapAndBridgeRouterFeeBugTest
[FAIL: TrustSwapAndBridgeRouter_InsufficientBridgeFee()] test_feeQuotedFromMinTrustOutUndercollateralizesBridge() (gas: 174729)

Encountered a total of 1 failing tests, 0 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```
