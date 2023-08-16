// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./library/SafeMath.sol";
import "./interface/IERC20.sol";
import "./interface/ITIFOERC20.sol";
import "./interface/IWarmup.sol";
import "./interface/IDistributor.sol";
import "./interface/IStakingRewardRelease.sol";
import "./interface/IStaking.sol";

import "./library/Address.sol";
import "./library/SafeERC20.sol";

// import "hardhat/console.sol";

contract TifoStaking is OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public TIFO;
    address public sTIFO;

    enum CONTRACTS {
        DISTRIBUTOR,
        WARMUP,
        LOCKER
    }

    struct Epoch {
        uint256 length;
        uint256 number;
        uint256 endBlock;
        uint256 distribute;
    }

    struct Claim {
        uint256 deposit;
        uint256 gons;
        uint256 expiry;
        bool lock;
    }

    Epoch public epoch;
    mapping(address => Claim) public warmupInfo;

    address public distributor;

    address public locker;
    uint256 public totalBonus;

    address public warmupContract; //
    uint256 public warmupPeriod;

    address public stakingRewardRelease;
    bool public stakingRewardReleaseSwitch;
    mapping(address => uint256) public stakingAmountOf;
    address public loanContract;
    struct RewardInfo {
        uint256 lastIndex;
        uint256 pending;
    }
    mapping(address => RewardInfo) public rewardInfoOf;
    bool public isRebaseOpen; 
    uint256 public realDistribute; 
    bool public isStakeSupport; 

    //event
    event Rebase(uint256 profit, uint256 epoch);
    event Stake(uint256 amount, address recipient);
    event Unstake(uint256 amount, bool trigger);

    /// @custom:oz-upgrades-unsafe-allow constructor
    // constructor() {
    //     _disableInitializers();
    // }

    function initialize(
        address _TIFO,
        address _sTIFO,
        uint256 _epochLength,
        uint256 _firstEpochNumber,
        uint256 _firstEpochBlock
    ) public initializer {
        __Ownable_init();
        require(_TIFO != address(0));
        TIFO = _TIFO;
        require(_sTIFO != address(0));
        sTIFO = _sTIFO;

        isStakeSupport = true;
        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endBlock: _firstEpochBlock,
            distribute: 0
        });
    }

    function stake(
        uint256 _amount,
        address _recipient
    ) external returns (bool) {
        require(isStakeSupport, "stake is not allowed");
        if (isRebaseOpen) rebase();

        IERC20(TIFO).safeTransferFrom(msg.sender, address(this), _amount);

        Claim memory info = warmupInfo[_recipient];
        require(!info.lock, "Deposits for account are locked");

        warmupInfo[_recipient] = Claim({
            deposit: info.deposit.add(_amount),
            gons: info.gons.add(ITIFOERC20(sTIFO).gonsForBalance(_amount)),
            expiry: epoch.number.add(warmupPeriod),
            lock: false
        });

        IERC20(sTIFO).safeTransfer(warmupContract, _amount);
        emit Stake(_amount, _recipient);
        return true;
    }

    function claim(address _recipient) public {
        Claim memory info = warmupInfo[_recipient];
        if (epoch.number >= info.expiry && info.expiry != 0) {
            delete warmupInfo[_recipient];
            uint256 stifoAmount = ITIFOERC20(sTIFO).balanceForGons(info.gons);
            IWarmup(warmupContract).retrieve(_recipient, stifoAmount);
            if (loanContract != msg.sender)
                _changeStakeAmount(_recipient, stifoAmount, 0);
        }
    }

    function forfeit() external {
        Claim memory info = warmupInfo[msg.sender];
        delete warmupInfo[msg.sender];

        IWarmup(warmupContract).retrieve(
            address(this),
            ITIFOERC20(sTIFO).balanceForGons(info.gons)
        );
        IERC20(TIFO).safeTransfer(msg.sender, info.deposit);
    }

    function toggleDepositLock() external {
        warmupInfo[msg.sender].lock = !warmupInfo[msg.sender].lock;
    }

    function unstake(uint256 _amount, bool _trigger) external {
        if (_trigger && isRebaseOpen) {
            rebase();
        }

        uint256 rewardAmount = 0;
        if (loanContract != msg.sender) {
            uint256 stakedAmount = stakingAmountOf[msg.sender];
            require(_amount <= stakedAmount, "amount too large");
            rewardAmount = IERC20(sTIFO).balanceOf(msg.sender).sub(stakedAmount);
            _changeStakeAmount(msg.sender, 0, _amount);

            _sendTIFOReward(msg.sender, rewardAmount);
        }

        uint256 sTifoFromSender = rewardAmount.add(_amount);
        IERC20(sTIFO).safeTransferFrom(
            msg.sender,
            address(this),
            sTifoFromSender
        );
        IERC20(TIFO).safeTransfer(msg.sender, _amount);
        emit Unstake(_amount, _trigger);
    }

    function index() public view returns (uint256) {
        return ITIFOERC20(sTIFO).index();
    }

    function rebase() private {
        if (epoch.endBlock <= block.number) {
            ITIFOERC20(sTIFO).rebase(realDistribute, epoch.number);

            epoch.endBlock = epoch.endBlock.add(epoch.length);
            epoch.number++;

            if (distributor != address(0)) {
                IDistributor(distributor).distribute();
            }

            uint256 balance = contractBalance();

            uint256 staked = ITIFOERC20(sTIFO).circulatingSupply();

            if (balance <= staked) {
                realDistribute = 0;
                // epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub(staked); 
                realDistribute = balance.sub(staked); 
            }

            emit Rebase(realDistribute, epoch.number);
        }
    }

    function _changeStakeAmount(
        address _staker,
        uint256 _increaseAmount,
        uint256 _decreaseAmount
    ) private {
        uint256 beforeAmount = stakingAmountOf[_staker];
        if (_increaseAmount > 0) {
            stakingAmountOf[_staker] = beforeAmount.add(_increaseAmount);
        } else if (_decreaseAmount > 0) {
            stakingAmountOf[_staker] = beforeAmount.sub(_decreaseAmount);
        }
    }

    function _sendTIFOReward(address _receiptor, uint256 _rewardAmount) private {
        if (_rewardAmount == 0) return;
        if (stakingRewardReleaseSwitch) {
            IStakingRewardRelease(stakingRewardRelease).addReward(
                _receiptor,
                _rewardAmount
            );

            IERC20(TIFO).safeTransfer(stakingRewardRelease, _rewardAmount);
        } else {
            IERC20(TIFO).safeTransfer(_receiptor, _rewardAmount);
        }
    }

    function contractBalance() public view returns (uint256) {
        return IERC20(TIFO).balanceOf(address(this)).add(totalBonus);
    }

    function giveLockBonus(uint256 _amount) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.add(_amount);
        IERC20(sTIFO).safeTransfer(locker, _amount);
    }

    function returnLockBonus(uint256 _amount) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.sub(_amount);
        IERC20(sTIFO).safeTransferFrom(locker, address(this), _amount);
    }

    function setContract(
        CONTRACTS _contract,
        address _address
    ) external onlyOwner {
        if (_contract == CONTRACTS.DISTRIBUTOR) {
            // 0
            distributor = _address;
        } else if (_contract == CONTRACTS.WARMUP) {
            // 1
            require(
                warmupContract == address(0),
                "Warmup cannot be set more than once"
            );
            warmupContract = _address;
        } else if (_contract == CONTRACTS.LOCKER) {
            // 2
            require(
                locker == address(0),
                "Locker cannot be set more than once"
            );
            locker = _address;
        }
    }

    function setWarmup(uint256 _warmupPeriod) external onlyOwner {
        warmupPeriod = _warmupPeriod;
    }

   
    function setStakingRewardRelease(
        address _contract,
        bool _switch
    ) external onlyOwner {
        if (_switch)
            require(address(0) != _contract, "not support zero address");
        stakingRewardRelease = _contract;
        stakingRewardReleaseSwitch = _switch;
    }


    function getNextDistribute() external view returns (uint256 distribute_) {
        return epoch.distribute;
    }

    function setLoanContract(address _contract) external onlyOwner {
        loanContract = _contract;
    }

    function getStakingAmount(
        address _addr
    ) external view returns (uint256 stakingAmount_) {
        return stakingAmountOf[_addr];
    }

    /**
     * @notice unstake stifo ,To pay Bonus
     * @param _recipient bonus to
     * @param _amount stifo amount
     */
    function unstakeAsBonus(address _recipient, uint256 _amount) external {
        require(msg.sender == loanContract, "no permission");
        IERC20(sTIFO).safeTransferFrom(msg.sender, address(this), _amount);
        _sendTIFOReward(_recipient, _amount);
    }


    function setRebaseStatus(bool _isRebaseOpen) external onlyOwner {
        isRebaseOpen = _isRebaseOpen;
    }

    function setDistribute(uint256 _distribute) external onlyOwner {
        epoch.distribute = _distribute;
    }



    function setBoolValue(uint256 _type, bool _value) external onlyOwner {
        if (_type == 0) {
            isStakeSupport = _value; 
        }
    }
}
