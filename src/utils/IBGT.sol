pragma solidity ^0.8.23;

interface IBGT {
    function redeem(address receiver, uint256 amount) external;
    function queueBoost(address validator, uint128 amount) external;
    function activateBoost(address validator) external;
    function dropBoost(address validator, uint128 amount) external;
    function unboostedBalanceOf(address account) external view returns (uint256);
}