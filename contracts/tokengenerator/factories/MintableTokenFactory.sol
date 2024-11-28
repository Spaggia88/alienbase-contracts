pragma solidity ^0.8.2;

import {IAlienbaseTokenFactory} from "../interfaces/IAlienbaseTokenFactory.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract MintableTokenFactory is IAlienbaseTokenFactory {

    address generator;

    constructor(address _generator) {
        generator = _generator;
    }


    function deploy(address creator, DeploymentParams calldata params, bytes calldata additionalData) external override {

        require(msg.sender == generator, "Unauthorized");
        
        MintableERC20 token = new MintableERC20(params.name, params.ticker, params.initialSupply, params.maxSupply, creator);
        emit TokenDeployed(address(token), creator);

    }


}

contract MintableERC20 is ERC20, ERC20Permit, Ownable {

    uint public maxSupply;

    constructor(
        string memory name,
        string memory symbol,
        uint initialSupply,
        uint _maxSupply,
        address creator
    ) ERC20(name, symbol) ERC20Permit(name) {
        _mint(creator, initialSupply);
        maxSupply = _maxSupply;
    }


    function mint(address to, uint256 amount) public onlyOwner {
        require(totalSupply() + amount <= maxSupply, "ERC20: cannot mint more tokens, cap exceeded");
        _mint(to, amount);
    }
}