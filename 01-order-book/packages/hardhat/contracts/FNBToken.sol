// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;


import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FNBToken is ERC20 {

    // Deploys the token with a fixed supply minted to the deployer
    // initialSUpply should be passed with 18 decimal places
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        _mint(msg.sender, initialSupply);
    }

}
