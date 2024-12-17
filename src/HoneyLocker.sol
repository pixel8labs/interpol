// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC721} from "solady/tokens/ERC721.sol";
import {ERC1155} from "solady/tokens/ERC1155.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib as STL} from "solady/utils/SafeTransferLib.sol";

import {BaseVaultAdapter as BVA} from "./adapters/BaseVaultAdapter.sol";
import {AdapterFactory} from "./AdapterFactory.sol";
import {IBGTStationGauge} from "./adapters/BGTStationAdapter.sol";
import {Constants} from "./Constants.sol";
import {IBGT} from "./utils/IBGT.sol";
import {HoneyQueen} from "./HoneyQueen.sol";
import {Beekeeper} from "./Beekeeper.sol";

import {console2} from "forge-std/console2.sol";

contract HoneyLocker is Ownable {
    /*###############################################################
                            ERRORS
    ###############################################################*/
    error HoneyLocker__AdapterAlreadyRegistered();
    error HoneyLocker__AdapterNotFound();

    error HoneyLocker__ExpirationNotMatching();
    error HoneyLocker__HasToBeLPToken();
    error HoneyLocker__NotExpiredYet();
    error HoneyLocker__WithdrawalFailed();
    error HoneyLocker__CannotBeLPToken();
    error HoneyLocker__TokenBlocked();
    error HoneyLocker__NotAuthorizedUpgrade();
    /*###############################################################
                            EVENTS
    ###############################################################*/
    event HoneyLocker__VaultRegistered(
        address indexed vault,
        address indexed adapter,
        address logic
    );
    
    event HoneyLocker__Deposited(address indexed LPToken, uint256 amountOrId);
    event HoneyLocker__LockedUntil(address indexed LPToken, uint256 expiration);
    event HoneyLocker__Withdrawn(address indexed LPToken, uint256 amountOrId);

    event HoneyLocker__Staked(address indexed vault, address indexed LPToken, uint256 amountOrId);
    event HoneyLocker__Unstaked(address indexed vault, address indexed LPToken, uint256 amountOrId);
    event HoneyLocker__Claimed(address indexed vault, address indexed rewardToken, uint256 amount);
    /*###############################################################
                            STORAGE
    ###############################################################*/
    mapping(string protocol => BVA adapter)         public              adapterOfProtocol;
    HoneyQueen                                      public immutable    honeyQueen;

    mapping(address LPToken => uint256 expiration)  public expirations;
    bool                                            public unlocked;
    address                                         public referrer;
    address                                         public treasury;            
    address                                         public operator;       
    
    /*###############################################################
                            CONSTRUCTOR
    ###############################################################*/
    constructor(address _honeyQueen, address _owner, address _referrer, bool _unlocked) {
        honeyQueen = HoneyQueen(_honeyQueen);
        _initializeOwner(_owner);
        unlocked = _unlocked;
        referrer = _referrer;
    }
    /*###############################################################
                            MODIFIERS
    ###############################################################*/
    modifier onlyValidAdapter(address vault) {
        if (address(_getAdapter(vault)) == address(0)) revert HoneyLocker__AdapterNotFound();
        _;
    }
    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && msg.sender != operator) revert Unauthorized();
        _;
    }
    modifier onlyUnblockedTokens(address _token) {
        if (!unlocked && honeyQueen.isTokenBlocked(_token)) revert HoneyLocker__TokenBlocked();
        _;
    }
    /*###############################################################
                            ADAPTERS MANAGEMENT
    ###############################################################*/
    function registerAdapter(string calldata protocol) external onlyOwner {
        BVA adapter = adapterOfProtocol[protocol];
        if (address(adapter) != address(0)) revert HoneyLocker__AdapterAlreadyRegistered();

        address newAdapter = AdapterFactory(honeyQueen.adapterFactory()).createAdapter(address(this), protocol);
        
        adapterOfProtocol[protocol] = BVA(newAdapter);
    }

    /**
     * @notice              Upgrades an adapter implementation for a protocol to a new version
     * @param protocol      The protocol name whose adapter should be upgraded
     * @dev                 Only callable by owner
     * @dev                 Will revert if upgrade is not authorized by HoneyQueen
     * @dev                 The new implementation must be compatible with the old one
     * @custom:emits        Adapter__Upgraded event from BaseVaultAdapter with old and new implementation addresses
     */
    function upgradeAdapter(string calldata protocol) external onlyOwner {
        BVA adapter = adapterOfProtocol[protocol];
        address authorizedLogic = HoneyQueen(honeyQueen).upgradeOf(adapter.implementation());
        if(authorizedLogic == address(0)) revert HoneyLocker__NotAuthorizedUpgrade();
        adapter.upgrade(authorizedLogic);
    }

    /*###############################################################
                            OWNER
    ###############################################################*/
    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /*###############################################################
                            INTERNAL
    ###############################################################*/
    function _getAdapter(address vault) internal view returns (BVA adapter) {
        return adapterOfProtocol[honeyQueen.protocolOfVault(vault)];
    }
    /*###############################################################
                            VAULT MANAGEMENT
    ###############################################################*/
    function stake(address vault, uint256 amount) external onlyValidAdapter(vault) onlyOwnerOrOperator {
        BVA adapter = _getAdapter(vault);
        address token = adapter.stakingToken(vault);

        ERC721(token).approve(address(adapter), amount);
        adapter.stake(vault, amount);

        emit HoneyLocker__Staked(vault, token, amount);
    }

    function unstake(address vault, uint256 amount) external onlyValidAdapter(vault) onlyOwnerOrOperator {
        BVA adapter = _getAdapter(vault);
        adapter.unstake(vault, amount);

        emit HoneyLocker__Unstaked(vault, adapter.stakingToken(vault), amount);
    }

    function claim(address vault) external onlyValidAdapter(vault) onlyOwnerOrOperator {
        BVA adapter = _getAdapter(vault);
        (address[] memory rewardTokens, uint256[] memory earned) = adapter.claim(vault);
        for (uint256 i; i < rewardTokens.length; i++) {
            emit HoneyLocker__Claimed(vault, rewardTokens[i], earned[i]);
        }
    }
    
    function wildcard(address vault, uint8 func, bytes calldata args) external onlyValidAdapter(vault) onlyOwnerOrOperator {
        BVA adapter = _getAdapter(vault);
        adapter.wildcard(vault, func, args);
    }
    /*###############################################################
                            BGT MANAGEMENT
    ###############################################################*/
    /*
        Claim directly the BGT rewards from the vault.
        vault HAS to be a BG Station vault.
        locker HAS to be the operator of the adapter.

    */
    function claimBGT(address vault) external onlyValidAdapter(vault) onlyOwnerOrOperator {
        BVA adapter = _getAdapter(vault);
        uint256 reward = IBGTStationGauge(vault).getReward(address(adapter));
        emit HoneyLocker__Claimed(vault, Constants.BGT, reward);
    }

    function burnBGTForBERA(uint256 _amount) external onlyOwnerOrOperator {
        IBGT(Constants.BGT).redeem(address(this), _amount);
        withdrawBERA(_amount);
    }

    function delegateBGT(uint128 amount, address validator) external onlyOwnerOrOperator {
        IBGT(Constants.BGT).queueBoost(validator, amount);
    }

    function activateBoost(address validator) external onlyOwnerOrOperator {
        IBGT(Constants.BGT).activateBoost(validator);
    }

    function cancelQueuedBoost(uint128 amount, address validator) external onlyOwnerOrOperator {
        IBGT(Constants.BGT).cancelBoost(validator, amount);
    }

    function dropBoost(uint128 amount, address validator) external onlyOwnerOrOperator {
        IBGT(Constants.BGT).dropBoost(validator, amount);
    }
    /*###############################################################
                            LP MANAGEMENT
    ###############################################################*/
    /// @notice Deposits and locks LP tokens in the HoneyLocker
    /// @dev Only the owner or migrating vault can call this function
    /// @param _LPToken The address of the LP token to deposit and lock
    /// @param _amountOrId The amount or ID of the LP token to deposit
    /// @param _expiration The expiration timestamp for the lock
    /// @custom:throws ExpirationNotMatching if the new expiration is less than the existing one for non-unlocked tokens
    /// @custom:emits Deposited event with the LP token address and amount or ID deposited
    /// @custom:emits LockedUntil event with the LP token address and expiration timestamp
    function depositAndLock(address _LPToken, uint256 _amountOrId, uint256 _expiration) external onlyOwnerOrOperator {

        if (!unlocked && expirations[_LPToken] != 0 && _expiration < expirations[_LPToken]) {
            revert HoneyLocker__ExpirationNotMatching();
        }

        expirations[_LPToken] = unlocked ? 0 : _expiration;

        // using transferFrom from ERC721 because same signature for ERC20
        // with the difference that ERC721 doesn't expect a return value
        ERC721(_LPToken).transferFrom(msg.sender, address(this), _amountOrId);

        emit HoneyLocker__Deposited(_LPToken, _amountOrId);
        emit HoneyLocker__LockedUntil(_LPToken, _expiration);
    }

    function withdrawLPToken(address _LPToken, uint256 _amountOrId) external onlyOwnerOrOperator {
        // if (HONEY_QUEEN.isRewardToken(_LPToken)) revert HasToBeLPToken();
        //if (expirations[_LPToken] == 0) revert HoneyLocker__HasToBeLPToken();
        if (block.timestamp < expirations[_LPToken]) revert HoneyLocker__NotExpiredYet();

        // self approval only needed for ERC20, try/catch in case it's an ERC721
        try ERC721(_LPToken).approve(address(this), _amountOrId) {} catch {}
        ERC721(_LPToken).transferFrom(address(this), recipient(), _amountOrId);
        emit HoneyLocker__Withdrawn(_LPToken, _amountOrId);
    }

    /*###############################################################
                            TOKENS WITHDRAWALS
    ###############################################################*/
    function withdrawBERA(uint256 _amount) public onlyOwnerOrOperator {
        uint256 fees = honeyQueen.computeFees(_amount);
        STL.safeTransferETH(recipient(), _amount - fees);
        Beekeeper(honeyQueen.beekeeper()).distributeFees{value: fees}(referrer, address(0), fees);
        emit HoneyLocker__Withdrawn(address(0), _amount - fees);
    }

    function withdrawERC20(address _token, uint256 _amount) external onlyUnblockedTokens(_token) onlyOwnerOrOperator {
        // cannot withdraw any lp token that has an expiration
        if (expirations[_token] != 0) revert HoneyLocker__CannotBeLPToken();
        Beekeeper beekeeper = Beekeeper(honeyQueen.beekeeper());
        uint256 fees = honeyQueen.computeFees(_amount);
        // self approval to be compliant with ERC20 transferFrom
        ERC721(_token).approve(address(this), _amount);
        // use ERC721 transferFrom because same signature for ERC20 and doesn't expect a return value
        ERC721(_token).transferFrom(address(this), recipient(), _amount - fees);
        ERC721(_token).transferFrom(address(this), address(beekeeper), fees);
        beekeeper.distributeFees(referrer, _token, fees);
        emit HoneyLocker__Withdrawn(_token, _amount - fees);
    }

    function withdrawERC721(address _token, uint256 _id) external onlyUnblockedTokens(_token) onlyOwnerOrOperator {
        if (expirations[_token] != 0) revert HoneyLocker__CannotBeLPToken();
        ERC721(_token).safeTransferFrom(address(this), recipient(), _id);
    }

    function withdrawERC1155(address _token, uint256 _id, uint256 _amount, bytes calldata _data)
        external
        onlyUnblockedTokens(_token)
        onlyOwnerOrOperator
    {
        if (expirations[_token] != 0) revert HoneyLocker__CannotBeLPToken();
        ERC1155(_token).safeTransferFrom(address(this), recipient(), _id, _amount, _data);
    }
    /*###############################################################
                            VIEW LOGIC
    ###############################################################*/
    /// @notice         Returns the recipient address for rewards and LP tokens withdrawals
    /// @dev            If treasury is set, returns treasury address. Otherwise, returns owner address.
    /// @return address The address of the recipient (either treasury or owner)
    function recipient() public view returns (address) {
        return treasury == address(0) ? owner() : treasury;
    }
    /*###############################################################
                            PUBLIC LOGIC
    ###############################################################*/
    receive() external payable {}
}
