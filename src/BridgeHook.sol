// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

contract HashedTimelockHook is BaseHook, ReentrancyGuard, Ownable {
    constructor(
        IPoolManager _manager,
        address initialOwner,
        int24 initialFeeProportional
    ) BaseHook(_manager) Ownable(initialOwner) {
        feeProportional = initialFeeProportional;
        resetContractState();
    }

    event HTLCERC20New(
        bytes32 indexed contractId,
        bool incoming,
        address counterparty,
        address tokenContract,
        uint256 amount,
        uint256 timelock
    );
    event HTLCERC20Withdraw(bytes32 indexed contractId);
    event HTLCERC20Refund(bytes32 indexed contractId);

    struct LockContract {
        bool incoming;
        address counterparty;
        address tokenContract;
        uint256 amount;
        uint256 timelock; // locked UNTIL this time. Unit depends on consensus algorithm. PoA, PoA and IBFT all use seconds. But Quorum Raft uses nano-seconds
        bytes32 preimage;
    }

    modifier contractExists(bytes32 _contractId) {
        require(haveContract(_contractId), "contractId does not exist");
        _;
    }

    modifier futureTimelock(uint256 _time) {
        require(_time > block.timestamp, "timelock time must be in the future");
        _;
    }

    modifier pastTimelock() {
        require(counterparty != address(0), "Not in settlement state");
        require(timelock <= block.timestamp, "Timelock not yet passed");
        _;
    }

    modifier hashlockMatches(bytes32 _hashlock, bytes32 _x) {
        require(_hashlock == sha256(abi.encodePacked(_x)), "hashlock hash does not match");
        _;
    }

    modifier transferable() {
        require(counterparty == address(0), "Contract is in settlement state");
        _;
    }

    modifier locked() {
        require(counterparty != address(0), "Not in settlement state");
        _;
    }

    function newContract(
        address _counterparty,
        bool _incoming,
        bytes32 _hashlock,
        uint256 _timelock,
        address _tokenContract,
        uint256 _amount
    ) external futureTimelock(_timelock) returns (bool) {
        if (_incoming) {
            require(_amount > 0, "Token amount must be > 0");
            require(IERC20(_tokenContract).allowance(_counterparty, address(this)) >= _amount, "Token allowance must be >= amount");
            IERC20(_tokenContract).transferFrom(_counterparty, address(this), _amount);
        }

        incoming = _incoming;
        counterparty = _counterparty;
        tokenContract = _tokenContract;
        amount = _amount;
        timelock = _timelock;
        hashlock = _hashlock;

        emit HTLCERC20New(_counterparty, _tokenContract, _amount, _hashlock, _timelock);

        return true;
    }

    function settle(bytes32 _preimage) external nonReentrant hashlockMatches(hashlock, _preimage) locked returns (bool) {
        if (incoming) {
            emit HTLCERC20Settle(hashlock, tokenContract, amount);
        } else {
            IERC20(tokenContract).transfer(counterparty, amount);
            emit HTLCERC20Settle(hashlock, tokenContract, amount);
        }
        resetContractState();
        return true;
    }

    function refund() external nonReentrant locked pastTimelock returns (bool) {
        if (!incoming) IERC20(tokenContract).transfer(counterparty, amount);
        emit HTLCERC20Refund(hashlock, tokenContract, amount);
        resetContractState();
        return true;
    }

    function transfer(address _tokenContract, uint256 _amount) external onlyOwner locked returns (bool) {
        IERC20(_tokenContract).transfer(counterparty, _amount);
        return true;
    }

    function resetContractState() internal {
        counterparty = address(0);
        tokenContract = address(0);
        amount = 0;
        timelock = 0;
        hashlock = 0x0;
    }

    mapping(bytes32 => LockContract) contracts;
    int24 feeProportional;

    // Use CurrencyLibrary and BalanceDeltaLibrary
    // to add some helper functions over the Currency and BalanceDelta
    // data types
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // Keeping track of user => referrer
    mapping(address => address) public referredBy;

    // Amount of points someone gets for referring someone else
    uint256 public constant POINTS_FOR_REFERRAL = 500 * 10 ** 18;

    // Set up hook permissions to return `true`
    // for the two hook functions we are using
    function getHookPermissions()
    public
    pure
    override
    returns (Hooks.Permissions memory)
    {
        return
        Hooks.Permissions({
        beforeInitialize : false,
        afterInitialize : false,
        beforeAddLiquidity : false,
        beforeRemoveLiquidity : false,
        afterAddLiquidity : true,
        afterRemoveLiquidity : false,
        beforeSwap : false,
        afterSwap : true,
        beforeDonate : false,
        afterDonate : false
        });
    }

    // Stub implementation of `afterSwap`
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        // We'll add more code here shortly
        return this.afterSwap.selector;
    }

    // Stub implementation for `afterAddLiquidity`
    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        // We'll add more code here shortly
        return this.afterAddLiquidity.selector;
    }
}
