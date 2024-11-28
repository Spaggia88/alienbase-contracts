pragma solidity ^0.8.2;

import {IAlienbaseTokenFactory} from "../interfaces/IAlienbaseTokenFactory.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";


contract SimpleTokenFactory is IAlienbaseTokenFactory {

    address generator;

    constructor(address _generator) {
        generator = _generator;
    }

    function deploy(address creator, DeploymentParams calldata params, bytes calldata additionalData) external override {

        require(msg.sender == generator, "Unauthorized");
        
        SimpleERC20 token = new SimpleERC20(params.name, params.ticker, params.initialSupply, creator);
        emit TokenDeployed(address(token), creator);

    }


}

contract SimpleERC20 is ERC20, ERC20Permit {

    constructor(
        string memory name,
        string memory symbol,
        uint initialSupply,
        address creator
    ) ERC20(name, symbol) ERC20Permit(name) {
        _mint(creator, initialSupply);
    }
}