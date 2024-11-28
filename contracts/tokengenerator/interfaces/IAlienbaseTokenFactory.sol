pragma solidity ^0.8.2;

interface IAlienbaseTokenFactory {

    struct DeploymentParams {
        uint factoryIndex;
        bool mintable;
        bool burnable;
        string name;
        string ticker;
        uint initialSupply;
        uint maxSupply;
        bool taxToken;
        uint sellTax;
        uint buyTax;
        uint liquidityShare;
        uint teamShare;
    }
    
    function deploy(address creator, DeploymentParams calldata params, bytes calldata additionalData) external;

    event TokenDeployed(address token, address creator);
}