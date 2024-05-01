// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

contract HashedTimelockHook is BaseHook, ReentrancyGuard, Ownable {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    mapping (bytes32 => LockContract) public contracts;
    int24 feeProportional;

    event HTLCERC20New(
        address indexed sender,
        address indexed receiver,
        address tokenContract,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock
    );
    event HTLCERC20Withdraw(bytes32 indexed hashlock);
    event HTLCERC20Refund(bytes32 indexed hashlock);

    struct LockContract {
        address sender;
        address receiver;
        address tokenContract;
        uint256 amount;
        // locked UNTIL this time. Unit depends on consensus algorithm.
        // PoA, PoA and IBFT all use seconds. But Quorum Raft uses nano-seconds
        uint256 timelock;
        bool withdrawn;
        bool refunded;
        bytes32 preimage;
    }

    modifier tokensTransferable(address _token, address _sender, uint256 _amount) {
        require(_amount > 0, "token amount must be > 0");
        require(
            ERC20(_token).allowance(_sender, address(this)) >= _amount,
            "token allowance must be >= amount"
        );
        _;
    }
    modifier futureTimelock(uint256 _time) {
        // only requirement is the timelock time is after the last blocktime (now).
        // probably want something a bit further in the future then this.
        // but this is still a useful sanity check:
        require(_time > block.timestamp, "timelock time must be in the future");
        _;
    }
    modifier contractExists(bytes32 _hashlock) {
        require(haveContract(_hashlock), "contract does not exist");
        _;
    }
    modifier hashlockMatches(bytes32 _hashlock, bytes32 _x) {
        require(
            _hashlock == sha256(abi.encodePacked(_x)),
            "hashlock hash does not match"
        );
        _;
    }
    modifier withdrawable(bytes32 _hashlock) {
        require(contracts[_hashlock].receiver == msg.sender, "withdrawable: not receiver");
        require(contracts[_hashlock].withdrawn == false, "withdrawable: already withdrawn");
        // if we want to disallow claim to be made after the timeout, uncomment the following line
        // require(contracts[_hashlock].timelock > now, "withdrawable: timelock time must be in the future");
        _;
    }
    modifier refundable(bytes32 _hashlock) {
        require(contracts[_hashlock].sender == msg.sender, "refundable: not sender");
        require(contracts[_hashlock].refunded == false, "refundable: already refunded");
        require(contracts[_hashlock].withdrawn == false, "refundable: already withdrawn");
        require(contracts[_hashlock].timelock <= block.timestamp, "refundable: timelock not yet passed");
        _;
    }

    function newContract(
        address _receiver,
        bytes32 _hashlock,
        uint256 _timelock,
        address _tokenContract,
        uint256 _amount
    )
    external
    tokensTransferable(_tokenContract, msg.sender, _amount)
    futureTimelock(_timelock)
    returns (bytes32 hashlock)
    {
        if (haveContract(_hashlock))
            revert("Contract already exists");

        if (!ERC20(_tokenContract).transferFrom(msg.sender, address(this), _amount))
            revert("transferFrom sender to this failed");

        contracts[_hashlock] = LockContract(
            msg.sender,
            _receiver,
            _tokenContract,
            _amount,
            _timelock,
            false,
            false,
            0x0
        );

        emit HTLCERC20New(
            msg.sender,
            _receiver,
            _tokenContract,
            _amount,
            _hashlock,
            _timelock
        );

        return _hashlock;
    }

    function withdraw(bytes32 _hashlock, bytes32 _preimage)
    external
    contractExists(_hashlock)
    hashlockMatches(_hashlock, _preimage)
    withdrawable(_hashlock)
    returns (bool)
    {
        LockContract storage c = contracts[_hashlock];
        c.preimage = _preimage;
        c.withdrawn = true;
        ERC20(c.tokenContract).transfer(c.receiver, c.amount);
        emit HTLCERC20Withdraw(_hashlock);
        return true;
    }

    function refund(bytes32 _hashlock)
    external
    contractExists(_hashlock)
    refundable(_hashlock)
    returns (bool)
    {
        LockContract storage c = contracts[_hashlock];
        c.refunded = true;
        ERC20(c.tokenContract).transfer(c.sender, c.amount);
        emit HTLCERC20Refund(_hashlock);
        return true;
    }

    function getContract(bytes32 _hashlock)
    public
    view
    returns (
        bytes32 hashlock,
        address sender,
        address receiver,
        address tokenContract,
        uint256 amount,
        uint256 timelock,
        bool withdrawn,
        bool refunded,
        bytes32 preimage
    )
    {
        if (haveContract(_hashlock) == false)
            return (0, address(0), address(0), address(0), 0, 0, false, false, 0);
        LockContract storage c = contracts[_hashlock];
        return (
        _hashlock,
        c.sender,
        c.receiver,
        c.tokenContract,
        c.amount,
        c.timelock,
        c.withdrawn,
        c.refunded,
        c.preimage
        );
    }


    function haveContract(bytes32 _hashlock)
    internal
    view
    returns (bool exists)
    {
        exists = (contracts[_hashlock].sender != address(0));
    }

    constructor(
        IPoolManager _manager,
        address initialOwner,
        int24 initialFeeProportional
    ) BaseHook(_manager) Ownable(initialOwner) {
        feeProportional = initialFeeProportional;
    }

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
