// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from "./BaseTest.t.sol";
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

    function quoteTransferRemote(uint32, bytes32, uint256 amount) external pure returns (uint256) {
        return amount / FEE_DIVISOR;
    }

    function transferRemote(uint32, bytes32, uint256, uint256, FinalityState) external payable returns (bytes32 transferId)
    {
        transferId = keccak256(abi.encodePacked(block.timestamp, msg.value));
    }
}

contract PoCPeriphery is BaseTest {
    address public constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant BASE_MAINNET_TRUST = 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3;
    address payable public constant BASE_MAINNET_WETH = payable(0x4200000000000000000000000000000000000006);
    int24 public constant TICK_SPACING_100 = 100;
    uint256 public constant OUTPUT_MULTIPLIER = 1e12;

    function test_submissionValidity()
        external
    {
        vm.warp(1);

        MockERC20 usdcTemplate = new MockERC20("", "", 0);
        MockERC20 trustTemplate = new MockERC20("", "", 0);
        MockWETH wethTemplate = new MockWETH();

        vm.etch(BASE_MAINNET_USDC, address(usdcTemplate).code);
        vm.etch(BASE_MAINNET_TRUST, address(trustTemplate).code);
        vm.etch(BASE_MAINNET_WETH, address(wethTemplate).code);

        MockERC20 usdcToken = MockERC20(BASE_MAINNET_USDC);
        MockERC20 trustToken = MockERC20(BASE_MAINNET_TRUST);

        usdcToken.initialize("USD Coin", "USDC", 6);
        trustToken.initialize("Trust Token", "TRUST", 18);
        MockWETH(BASE_MAINNET_WETH).initialize("Wrapped Ether", "WETH", 18);

        TrustSwapAndBridgeRouter router = new TrustSwapAndBridgeRouter();

        MockSlipstreamSwapRouter swapRouterTemplate = new MockSlipstreamSwapRouter(OUTPUT_MULTIPLIER);
        MockCLFactory clFactoryTemplate = new MockCLFactory();
        MockMetaERC20HubFeeByAmount metaTemplate = new MockMetaERC20HubFeeByAmount();

        vm.etch(router.slipstreamSwapRouter(), address(swapRouterTemplate).code);
        vm.etch(address(router.slipstreamFactory()), address(clFactoryTemplate).code);
        vm.etch(address(router.metaERC20Hub()), address(metaTemplate).code);

        MockCLFactory clFactory = MockCLFactory(address(router.slipstreamFactory()));
        clFactory.setPool(BASE_MAINNET_USDC, BASE_MAINNET_TRUST, TICK_SPACING_100, address(0xBEEF));

        address user = makeAddr("user");
        uint256 amountIn = 1e6;
        uint256 minTrustOut = 1e12;
        uint256 expectedAmountOut = amountIn * OUTPUT_MULTIPLIER;
        uint256 quotedFee = MockMetaERC20HubFeeByAmount(address(router.metaERC20Hub())).quoteTransferRemote(
            router.recipientDomain(), bytes32(uint256(uint160(user))), minTrustOut
        );
        uint256 actualFee = MockMetaERC20HubFeeByAmount(address(router.metaERC20Hub())).quoteTransferRemote(
            router.recipientDomain(), bytes32(uint256(uint160(user))), expectedAmountOut
        );

        vm.startPrank(user);
        usdcToken.mint(user, amountIn * 2);
        usdcToken.approve(address(router), type(uint256).max);

        bytes memory path = abi.encodePacked(BASE_MAINNET_USDC, TICK_SPACING_100, BASE_MAINNET_TRUST);

        vm.expectRevert(abi.encodeWithSignature("TrustSwapAndBridgeRouter_InsufficientBridgeFee()"));
        router.swapAndBridgeWithERC20{ value: quotedFee }(BASE_MAINNET_USDC, amountIn, path, minTrustOut, user);

        (uint256 amountOut,) =
            router.swapAndBridgeWithERC20{ value: actualFee }(BASE_MAINNET_USDC, amountIn, path, minTrustOut, user);
        vm.stopPrank();

        assertEq(amountOut, expectedAmountOut, "valid fee bridges expected amount");
    }
}
