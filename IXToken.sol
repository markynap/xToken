//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./IERC20.sol";

/**
 * Exempt Surge Interface
 */
interface IXToken is IERC20 {
    function mintXToken(uint256 amount) external returns(bool);
    function redeemNative(uint256 amount) external returns(bool);
    function getNativeAddress() external view returns(address);
}


