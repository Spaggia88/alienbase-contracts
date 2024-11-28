pragma solidity ^0.8.20;


import "@openzeppelin/contracts-5/access/Ownable.sol";
import {IAlienbaseTokenFactory} from "../interfaces/IAlienbaseTokenFactory.sol";
import "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-5/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-5/token/ERC20/extensions/ERC20Permit.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IUniswapV2Factory.sol";


contract TaxTokenFactory is IAlienbaseTokenFactory {

    IUniswapV2Router02 router;
    address generator;

    constructor(address _generator, IUniswapV2Router02 _router) {
        router = _router;
        generator = _generator;
    }

    function deploy(address creator, DeploymentParams calldata params, bytes calldata additionalData) external override {

        require(msg.sender == generator, "Unauthorized");

        // bytes memory data = additionalData;

        address developmentWallet = additionalData.length > 0 ? abi.decode(additionalData, (address)) : address(0);
        
        TaxableERC20 token = new TaxableERC20(
            creator,
            params.name,
            params.ticker,
            params.initialSupply,
            router,
            params.buyTax,
            params.sellTax,
            params.liquidityShare,
            developmentWallet    
        );
        emit TokenDeployed(address(token), creator);

    }

}


contract TaxableERC20 is Ownable, ERC20, ERC20Permit {
    uint256 public constant MAX_FEE = 0.03e18;

    IUniswapV2Router02 public uniswapV2Router;
    address public immutable uniswapV2Pair;

    bool public taxEnabled = true;
    bool private isSwappingBack;

    uint256 public swapTokensAtAmount;
    uint256 public buyTotalFees;
    uint256 public sellTotalFees;
    uint256 public feesToLiquidity;
    uint256 public feesToDevelopment;

    address public developmentWallet;


    mapping(address => bool) public isExcludedFromFees;
    mapping(address => bool) public automatedMarketMakerPairs;

    event ExcludeFromFees(address account, bool isExcluded);

    event SetAutomatedMarketMakerPair(address pair, bool value);
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiquidity
    );

    constructor(
        address creator,
        string memory name,
        string memory symbol,
        uint initialSupply,
        IUniswapV2Router02 _router,
        uint _buyFees,
        uint _sellFees,
        uint _feesToLiquidity,
        address _developmentWallet
    ) Ownable(creator) ERC20(name, symbol) ERC20Permit(name) {

        require(_feesToLiquidity <= 1e18, "Invalid fee split");
        require(_buyFees <= MAX_FEE && _sellFees <= MAX_FEE, "Invalid fee");

        _mint(creator, initialSupply);

        swapTokensAtAmount = totalSupply() / 1000;

        uniswapV2Router = _router;

        uniswapV2Pair = IUniswapV2Factory(_router.factory()).createPair(address(this), _router.WETH());
        taxEnabled = true;

        buyTotalFees = _buyFees;
        sellTotalFees = _sellFees;

        feesToLiquidity = _feesToLiquidity;
        feesToDevelopment = 1e18 - _feesToLiquidity;

        if(_developmentWallet != address(0)) {
            developmentWallet = _developmentWallet;
        } else {
            developmentWallet = creator;
        }
        

        _setAutomatedMarketMakerPair(uniswapV2Pair, true);
        _approve(address(this), address(uniswapV2Router), type(uint256).max);
        _excludeFromFees(address(this), true);
    }

    function _transferOwnership(address newOwner) internal override {

        address oldOwner = owner();
        if (oldOwner != address(0)) {
            _excludeFromFees(oldOwner, false);
        }
        _excludeFromFees(newOwner, true);
        super._transferOwnership(newOwner);
    }

    
    function setTaxEnabled(bool value) external onlyOwner {
        taxEnabled = value;
    }

    function setDevelopmentWallet(address _newWallet) external {
        require(msg.sender == developmentWallet || msg.sender == owner(), "Unauthorized");
        developmentWallet = _newWallet;
    }

    function setFeeSplit(uint _newFeesToLiquidity) external onlyOwner {
        require(_newFeesToLiquidity <= 1e18, "Invalid fee split");

        feesToLiquidity = _newFeesToLiquidity;
        feesToDevelopment = 1e18 - _newFeesToLiquidity;

    }

    function setSwapTokensAtAmount(uint256 amount) external onlyOwner {
        uint256 _totalSupply = totalSupply();
        require(amount >= (_totalSupply * 1) / 100000, "Swap amount cannot be lower than 0.001% total supply.");
        require(amount <= (_totalSupply * 5) / 1000, "Swap amount cannot be higher than 0.5% total supply.");
        swapTokensAtAmount = amount;
    }

    function setBuyFees(uint256 _buyFee) external onlyOwner {
        require(_buyFee <= MAX_FEE, "Must keep fees at 3% or less");
        buyTotalFees = _buyFee;
    }

    function setSellFees(uint256 _sellFee) external onlyOwner {
        require(_sellFee <= MAX_FEE, "Must keep fees at 3% or less");
        sellTotalFees = _sellFee;
    }

    function _excludeFromFees(address account, bool value) internal {
        isExcludedFromFees[account] = value;
        emit ExcludeFromFees(account, value);
    }

    function excludeFromFees(address account, bool value) external onlyOwner {
        _excludeFromFees(account, value);
    }

    function bulkExcludeFromFees(address[] calldata accounts, bool value) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            _excludeFromFees(accounts[i], value);
        }
    }

    receive() external payable {}

    function _setAutomatedMarketMakerPair(address pair, bool value) internal {
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        _setAutomatedMarketMakerPair(pair, value);
    }

    function _update(address from, address to, uint256 amount) internal override {
        bool takeFee = taxEnabled && !isSwappingBack && !(isExcludedFromFees[from] || isExcludedFromFees[to]);

        if (takeFee) {
            uint256 fees = 0;
            // on sell
            if (automatedMarketMakerPairs[to]) {
                fees = amount * sellTotalFees / 1e18;
            }
            // on buy
            else if (automatedMarketMakerPairs[from]) {
                fees = amount * buyTotalFees / 1e18;
            }

            if (fees > 0) {
                amount -= fees;
                super._update(from, address(this), fees);
            }
        }

        if (takeFee && !automatedMarketMakerPairs[from] && balanceOf(address(this)) >= swapTokensAtAmount) {
            isSwappingBack = true;
            _swapBack();
            isSwappingBack = false;
        }

        super._update(from, to, amount);
    }

    function _swapTokensForETH(uint256 tokenAmount) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) internal {
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            address(this), //liquidity is stored in the contract
            block.timestamp
        );
    }

    function _swapBack() internal {
        uint256 contractBalance = balanceOf(address(this));
        bool success;

        if (contractBalance == 0) {
            return;
        }

        if (contractBalance > swapTokensAtAmount * 10) {
            contractBalance = swapTokensAtAmount * 10;
        }

        uint256 liquidityTokens = (contractBalance * feesToLiquidity) /
            2e18;
        uint256 amountToSwapForETH = contractBalance - liquidityTokens;

        uint256 initialETHBalance = address(this).balance;

        _swapTokensForETH(amountToSwapForETH);

        //approximate eth value on the contract including unswapped tokens
        uint256 ethBalance = (address(this).balance - initialETHBalance) * 1e18 / 
            (feesToLiquidity/2 + feesToDevelopment);
        
        uint256 ethForLiquidity = ethBalance * feesToLiquidity / 2e18;

        if(ethForLiquidity > address(this).balance) {
            ethForLiquidity = address(this).balance;
        }


        if (liquidityTokens > 0 && ethForLiquidity > 0) {
            _addLiquidity(liquidityTokens, ethForLiquidity);
            emit SwapAndLiquify(
                amountToSwapForETH,
                ethForLiquidity,
                liquidityTokens
            );
        }

        //send remainder to dev

        (success, ) = address(developmentWallet).call{value: address(this).balance}(
            ""
        );

    }

}