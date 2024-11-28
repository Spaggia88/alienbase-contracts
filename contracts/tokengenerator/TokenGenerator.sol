// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/access/Ownable.sol";
import {IAlienbaseTokenFactory} from "./interfaces/IAlienbaseTokenFactory.sol";

contract TokenGenerator is Ownable {

    address[] public factories;
    uint public creationFee;

    constructor() {
        
    }

    function addFactory(address _newFactory) external onlyOwner {
        factories.push(_newFactory);
    }
    
    function removeFactory(uint index) external onlyOwner {
        require(index < factories.length, "Invalid Index");
        factories[index] = factories[factories.length - 1];
        factories.pop();
    }

    function setFee(uint _fee) external onlyOwner {
        creationFee = _fee;
    }  

    function deployToken(IAlienbaseTokenFactory.DeploymentParams calldata params, bytes calldata additionalData) external payable {

        require(msg.value == creationFee, "Missing or exceeding payment");

        IAlienbaseTokenFactory tokenFactory = IAlienbaseTokenFactory(factories[params.factoryIndex]);
        tokenFactory.deploy(tx.origin, params, additionalData);

        (bool success, ) = owner().call{value: msg.value}("");
        require(success, "Failed to deliver fee");

    }

}


