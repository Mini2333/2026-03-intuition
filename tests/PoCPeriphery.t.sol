// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TrustSwapAndBridgeRouter } from "contracts/TrustSwapAndBridgeRouter.sol";
import { ISlipstreamSwapRouter } from "contracts/interfaces/external/aerodrome/ISlipstreamSwapRouter.sol";
import { FinalityState } from "contracts/interfaces/external/metalayer/IMetaERC20Hub.sol";

contract MockERC20 {
    bool public initialized;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function initialize() external {
        require(!initialized, "already initialized");
        initialized = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockSlipstreamSwapRouter {
    uint256 public outputMultiplier = 1e12;

    function exactInput(ISlipstreamSwapRouter.ExactInputParams calldata params) external returns (uint256 amountOut) {
        amountOut = params.amountIn * outputMultiplier;
        require(amountOut >= params.amountOutMinimum, "Too little received");

        address tokenIn = address(bytes20(params.path[:20]));
        address tokenOut = address(bytes20(params.path[params.path.length - 20:]));

        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        MockERC20(tokenOut).mint(params.recipient, amountOut);
    }
}

contract MockCLFactory {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        pools[keccak256(abi.encode(tokenA, tokenB, tickSpacing))] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        return pools[keccak256(abi.encode(tokenA, tokenB, tickSpacing))];
    }
}

contract MockMetaERC20HubAmountBased {
    uint256 public constant FEE_DIVISOR = 1000;
    uint256 public transferCounter;

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
        require(msg.value >= amount / FEE_DIVISOR, "insufficient fee");
        transferCounter++;
        transferId = keccak256(abi.encodePacked(transferCounter, block.timestamp, msg.sender));
    }
}

contract PoCPeriphery is Test {
    function test_submissionValidity() external {
        TrustSwapAndBridgeRouter router = new TrustSwapAndBridgeRouter();

        address user = makeAddr("user");
        int24 tickSpacing = 100;

        MockERC20 usdcTemplate = new MockERC20();
        MockERC20 trustTemplate = new MockERC20();
        MockSlipstreamSwapRouter swapRouterTemplate = new MockSlipstreamSwapRouter();
        MockCLFactory clFactoryTemplate = new MockCLFactory();
        MockMetaERC20HubAmountBased amountBasedHubTemplate = new MockMetaERC20HubAmountBased();

        vm.etch(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, address(usdcTemplate).code);
        vm.etch(0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3, address(trustTemplate).code);
        vm.etch(router.slipstreamSwapRouter(), address(swapRouterTemplate).code);
        vm.etch(address(router.slipstreamFactory()), address(clFactoryTemplate).code);
        vm.etch(address(router.metaERC20Hub()), address(amountBasedHubTemplate).code);

        MockERC20 usdc = MockERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        MockERC20 trust = MockERC20(0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3);
        MockCLFactory clFactory = MockCLFactory(address(router.slipstreamFactory()));
        MockMetaERC20HubAmountBased hub = MockMetaERC20HubAmountBased(address(router.metaERC20Hub()));

        usdc.initialize();
        trust.initialize();
        clFactory.setPool(address(usdc), address(trust), tickSpacing, address(0xDEAD1));

        uint256 amountIn = 1e6;
        uint256 minTrustOut = 1e12;
        uint256 actualAmountOut = amountIn * 1e12;
        uint256 lowFee = hub.quoteTransferRemote(router.recipientDomain(), bytes32(uint256(uint160(user))), minTrustOut);
        uint256 requiredFee = hub.quoteTransferRemote(
            router.recipientDomain(), bytes32(uint256(uint160(user))), actualAmountOut
        );
        assertLt(lowFee, requiredFee);

        usdc.mint(user, amountIn);
        vm.prank(user);
        usdc.approve(address(router), type(uint256).max);
        vm.deal(user, lowFee);

        bytes memory path = abi.encodePacked(address(usdc), tickSpacing, address(trust));
        vm.prank(user);
        vm.expectRevert(bytes("insufficient fee"));
        router.swapAndBridgeWithERC20{ value: lowFee }(address(usdc), amountIn, path, minTrustOut, user);

        assertEq(hub.transferCounter(), 0);
    }
}
