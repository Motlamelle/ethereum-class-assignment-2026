// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;


import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PNPToken is ERC20 {

    // Deploys the token with a fixed supply minted to the deployer
    // initialSUpply should be passed with 18 decimal places
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }

}
