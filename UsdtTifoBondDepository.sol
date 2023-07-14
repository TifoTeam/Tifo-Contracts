// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./library/SafeMath.sol";
import "./library/Address.sol";
import "./library/SafeERC20.sol";
import "./library/FixedPoint.sol";
import "./interface/IERC20.sol";
import "./interface/ITreasury.sol";
import "./interface/IBondCalculator.sol";
import "./interface/IStaking.sol";
import "./interface/IStakingHelper.sol";
import "./base/ERC20Permit.sol";
import "./interface/IStakingConfig.sol";
import "./library/TransferHelper.sol";


// import "./base/Policy.sol";

// import "hardhat/console.sol";

contract UsdtTifoBondDepository is OwnableUpgradeable {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /* ======== EVENTS ======== */

    event BondCreated(
        uint256 deposit,
        uint256 indexed payout,
        uint256 indexed expires,
        uint256 indexed priceInUSD
    );
    event BondRedeemed(
        address indexed recipient,
        uint256 payout,
        uint256 remaining
    );
    event BondPriceChanged(
        uint256 indexed priceInUSD,
        uint256 indexed internalPrice,
        uint256 indexed debtRatio
    );
    event ControlVariableAdjustment(
        uint256 initialBCV,
        uint256 newBCV,
        uint256 adjustment,
        bool addition
    );

    event SetMinBondPrice(
        address indexed sender,
        uint256 indexed oldPrice,
        uint256 indexed newPrice
    );

    event SetBCV(
        address indexed sender,
        uint256 indexed oldBCV,
        uint256 indexed newBCV
    );

    event SetVestingTerm(
        address indexed sender,
        uint256 indexed oldVestingTerm,
        uint256 indexed newVestingTerm
    );

    /* ======== STATE VARIABLES ======== */

    address public TIFO; // token given as payment for bond
    address public principle; // token used to create bond
    address public treasury; // mints TIFO when receives principle
    address public DAO; //【receives profit share from bond】

    bool public isLiquidityBond; // LP and Reserve bonds are treated slightly different
    address public bondCalculator; // 【 calculates value of LP tokens】

    address public staking; // to auto-stake payout
    address public stakingHelper; // to stake and claim if no staking warmup
    bool public useHelper;

    Terms public terms; // stores terms for new bonds
    Adjust public adjustment; // 【stores adjustment to BCV data】

    mapping(address => Bond) public bondInfo; // 【stores bond information for depositors】

    uint256 public totalDebt; // 【total value of outstanding bonds; used for pricing】
    uint256 public lastDecay; // 【reference block for debt decay】

    /* ======== STRUCTS ======== */

    //【Info for creating new bonds】
    struct Terms {
        uint256 controlVariable; //  【scaling variable for price】
        uint256 vestingTerm; // 【in blocks】
        uint256 minimumPrice; // 【vs principle value】
        uint256 maxPayout; // 【in thousandths of a %. i.e. 500 = 0.5%】
        uint256 fee; // 【as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)】
        uint256 maxDebt; // 【9 decimal debt ratio, max % total supply created as debt】
    }

    //  【Info about each type of bond】
    struct Bond {
        uint256 payout; // 【TIFO remaining to be paid】
        uint256 vesting; // Blocks left to vest
        uint256 lastBlock; // Last interaction
        uint256 pricePaid; // In DAI, for front end viewing
    }

    //【Info for incremental adjustments to control variable 】
    struct Adjust {
        bool add; // addition or subtraction
        uint256 rate; // increment
        uint256 target; // BCV when adjustment finished
        uint256 buffer; // minimum length (in blocks) between adjustments
        uint256 lastBlock; // block when last adjustment made
    }

    event Deposit(uint256 indexed amount, uint256 maxPrice, address depositor);

    uint256 public priceBase;
    address public metaNftStakingAddress; //no use
    uint256 public feeRateForMetaNftStaking; //no use
    uint256 public feeDecForMetaNftStaking; // no use
    address public stakingConfig;

    //deploy method
    function initialize(
        address _TIFO,
        address _principle,
        address _treasury,
        address _DAO,
        address _bondCalculator
    ) public initializer {
        __Ownable_init();
        require(_TIFO != address(0));
        TIFO = _TIFO;
        require(_principle != address(0));
        principle = _principle;
        require(_treasury != address(0));
        treasury = _treasury;
        require(_DAO != address(0));
        DAO = _DAO;
        // bondCalculator should be address(0) if not LP bond
        bondCalculator = _bondCalculator;
        isLiquidityBond = (_bondCalculator != address(0));
    }

    function initializeBondTerms(
        uint256 _controlVariable,
        uint256 _vestingTerm,
        uint256 _minimumPrice,
        uint256 _maxPayout,
        uint256 _fee,
        uint256 _maxDebt,
        uint256 _initialDebt
    ) external onlyOwner {
        require(terms.controlVariable == 0, "Bonds must be initialized from 0");
        terms = Terms({
            controlVariable: _controlVariable,
            vestingTerm: _vestingTerm,
            minimumPrice: _minimumPrice,
            maxPayout: _maxPayout,
            fee: _fee,
            maxDebt: _maxDebt
        });
        totalDebt = _initialDebt;
        lastDecay = block.number;
    }

    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER {
        VESTING,
        PAYOUT,
        FEE,
        DEBT
    }

    function setBondTerms(PARAMETER _parameter, uint256 _input)
        external
        onlyOwner
    {
        if (_parameter == PARAMETER.VESTING) {
            // 0
            require(_input >= 10000, "Vesting must be longer than 36 hours");
            terms.vestingTerm = _input;
        } else if (_parameter == PARAMETER.PAYOUT) {
            // 1
            require(_input <= 1000, "Payout cannot be above 1 percent");
            terms.maxPayout = _input;
        } else if (_parameter == PARAMETER.FEE) {
            // 2
            require(_input <= 10000, "DAO fee cannot exceed payout");
            terms.fee = _input;
        } else if (_parameter == PARAMETER.DEBT) {
            // 3
            terms.maxDebt = _input;
        }
    }

    function setAdjustment(
        bool _addition,
        uint256 _increment,
        uint256 _target,
        uint256 _buffer
    ) external onlyOwner {
        require(
            _increment <= terms.controlVariable.mul(25).div(1000),
            "Increment too large"
        );

        adjustment = Adjust({
            add: _addition,
            rate: _increment,
            target: _target,
            buffer: _buffer,
            lastBlock: block.number
        });
    }

    function setStaking(address _staking, bool _helper) external onlyOwner {
        require(_staking != address(0));
        if (_helper) {
            useHelper = true;
            stakingHelper = _staking;
        } else {
            useHelper = false;
            staking = _staking;
        }
    }

    /* ======== USER FUNCTIONS ======== */

    function deposit(
        uint256 _amount,
        uint256 _maxPrice,
        address _depositor
    ) external returns (uint256) {
        require(_depositor != address(0), "Invalid address");

        decayDebt();
        require(totalDebt <= terms.maxDebt, "Max capacity reached");

        uint256 priceInUSD = bondPriceInUSD(); // Stored in bond info
        uint256 nativePrice = _bondPrice();

        require(
            _maxPrice >= nativePrice,
            "Slippage limit: more than max price"
        ); // slippage protection
        uint256 value = ITreasury(treasury).valueOfToken(principle, _amount);
        uint256 payout = payoutFor(value);

        require(payout >= 10000000, "Bond too small"); // must be > 0.01 TIFO ( underflow protection )
        require(payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        // 【profits are calculated】
        uint256 fee = (value.sub(payout)).mul(terms.fee).div(10000);
        uint256 profit = value.sub(payout).sub(fee);

        // uint256 fee = payout.mul(terms.fee).div(10000);
        // //
        // uint256 profit = value.sub(payout).sub(fee);

        /**
            principle is transferred in
            approved and
            deposited into the treasury, returning (_amount - profit) TIFO
         */
        IERC20(principle).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(principle).approve(address(treasury), _amount);
        ITreasury(treasury).deposit(_amount, principle, profit);

        if (fee != 0) {
            // fee is transferred to dao
            IERC20(TIFO).safeTransfer(DAO, fee);
        }

        // 【total debt is increased】
        totalDebt = totalDebt.add(value);

        //【depositor info is stored】
        bondInfo[_depositor] = Bond({
            payout: bondInfo[_depositor].payout.add(payout),
            vesting: terms.vestingTerm,
            lastBlock: block.number,
            pricePaid: priceInUSD
        });

        // indexed events are emitted
        emit BondCreated(
            _amount,
            payout,
            block.number.add(terms.vestingTerm),
            priceInUSD
        );
        emit BondPriceChanged(bondPriceInUSD(), _bondPrice(), debtRatio());

        adjust(); // control variable is adjusted
        emit Deposit(_amount, _maxPrice, _depositor);
        return payout;
    }

    function redeem(address _recipient, bool _stake)
        external
        returns (uint256)
    {
        Bond memory info = bondInfo[_recipient];

        uint256 percentVested = percentVestedFor(_recipient); // (blocks since last interaction / vesting term remaining)

        if (percentVested >= 10000) {
            //【if fully vested】
            delete bondInfo[_recipient]; // delete user info
            emit BondRedeemed(_recipient, info.payout, 0); // emit bond data
            return stakeOrSend(_recipient, _stake, info.payout); // pay user everything due
        } else {
            uint256 payout = info.payout.mul(percentVested).div(10000);

            // 【store updated deposit info】
            bondInfo[_recipient] = Bond({
                payout: info.payout.sub(payout),
                vesting: info.vesting.sub(block.number.sub(info.lastBlock)),
                lastBlock: block.number,
                pricePaid: info.pricePaid
            });

            emit BondRedeemed(_recipient, payout, bondInfo[_recipient].payout);
            return stakeOrSend(_recipient, _stake, payout);
        }
    }

    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    /**
     *  @notice allow user to stake payout automatically
     *  @param _stake bool
     *  @param _amount uint
     *  @return uint
     */
    function stakeOrSend(
        address _recipient,
        bool _stake,
        uint256 _amount
    ) internal returns (uint256) {
        if (!_stake) {
            // 【if user does not want to stake】
            IERC20(TIFO).transfer(_recipient, _amount); // send payout
        } else {
            // 【if user wants to stake】
            if (useHelper) {
                //【use if staking warmup is 0】
                IERC20(TIFO).approve(stakingHelper, _amount);
                IStakingHelper(stakingHelper).stake(_amount, _recipient);
            } else {
                IERC20(TIFO).approve(staking, _amount);
                IStaking(staking).stakeTIFO(
                    _amount,
                    _recipient,
                    defaultRebaseRateInfoId(),
                    0
                );
                // IStaking(staking).stake(_amount, _recipient);
            }
        }
        return _amount;
    }

    /**
     *  @notice 【makes incremental adjustment to control variable】
     */
    function adjust() internal {
        uint256 blockCanAdjust = adjustment.lastBlock.add(adjustment.buffer);
        if (adjustment.rate != 0 && block.number >= blockCanAdjust) {
            uint256 initial = terms.controlVariable;
            if (adjustment.add) {
                terms.controlVariable = terms.controlVariable.add(
                    adjustment.rate
                );
                if (terms.controlVariable >= adjustment.target) {
                    adjustment.rate = 0;
                }
            } else {
                terms.controlVariable = terms.controlVariable.sub(
                    adjustment.rate
                );
                if (terms.controlVariable <= adjustment.target) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastBlock = block.number;
            emit ControlVariableAdjustment(
                initial,
                terms.controlVariable,
                adjustment.rate,
                adjustment.add
            );
        }
    }

    /**
     *  @notice reduce total debt
     */
    function decayDebt() internal {
        totalDebt = totalDebt.sub(debtDecay());
        lastDecay = block.number;
    }

    /* ======== VIEW FUNCTIONS ======== */

    function maxPayout() public view returns (uint256) {
        return IERC20(TIFO).totalSupply().mul(terms.maxPayout).div(100000);
    }

    function payoutFor(uint256 _value) public view returns (uint256) {
        return
            FixedPoint.fraction(_value, bondPrice()).decode112with18().div(
                1e16
            );
    }

    function bondPrice() public view returns (uint256 price_) {
        price_ = terms.controlVariable.mul(debtRatio()).add(priceBase).div(1e7);
        if (price_ < terms.minimumPrice) {
            price_ = terms.minimumPrice;
        }
    }

    function _bondPrice() internal returns (uint256 price_) {
        price_ = terms.controlVariable.mul(debtRatio()).add(priceBase).div(1e7);
        if (price_ < terms.minimumPrice) {
            price_ = terms.minimumPrice;
        }
        //  else if (terms.minimumPrice != 0) {
        //     terms.minimumPrice = 0;
        // }
    }

    function bondPriceInUSD() public view returns (uint256 price_) {
        if (isLiquidityBond) {
            price_ = bondPrice()
                .mul(IBondCalculator(bondCalculator).markdown(principle))
                .div(100);
        } else {
            price_ = bondPrice().mul(10**IERC20(principle).decimals()).div(100);
        }
    }

    function debtRatio() public view returns (uint256 debtRatio_) {
        uint256 supply = IERC20(TIFO).totalSupply();
        // uint256 currentDebt = currentDebt().mul(1e9);
        // uint256 currentDebtToLittleValue = currentDebt.div(10);
        debtRatio_ = FixedPoint
            .fraction(currentDebt().mul(1e9), supply)
            .decode112with18()
            .div(1e18);
    }

    /**
     *  @notice debt ratio in same terms for reserve or liquidity bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns (uint256) {
        if (isLiquidityBond) {
            return
                debtRatio()
                    .mul(IBondCalculator(bondCalculator).markdown(principle))
                    .div(1e9);
        } else {
            return debtRatio();
        }
    }

    function currentDebt() public view returns (uint256) {
        return totalDebt.sub(debtDecay());
    }

    function debtDecay() public view returns (uint256 decay_) {
        uint256 blocksSinceLast = block.number.sub(lastDecay);
        decay_ = totalDebt.mul(blocksSinceLast).div(terms.vestingTerm);
        if (decay_ > totalDebt) {
            decay_ = totalDebt;
        }
    }

    function percentVestedFor(address _depositor)
        public
        view
        returns (uint256 percentVested_)
    {
        Bond memory bond = bondInfo[_depositor];
        uint256 blocksSinceLast = block.number.sub(bond.lastBlock);
        uint256 vesting = bond.vesting;

        if (vesting > 0) {
            percentVested_ = blocksSinceLast.mul(10000).div(vesting);
        } else {
            percentVested_ = 0;
        }
    }

    function pendingPayoutFor(address _depositor)
        external
        view
        returns (uint256 pendingPayout_)
    {
        uint256 percentVested = percentVestedFor(_depositor);
        uint256 payout = bondInfo[_depositor].payout;

        if (percentVested >= 10000) {
            pendingPayout_ = payout;
        } else {
            pendingPayout_ = payout.mul(percentVested).div(10000);
        }
    }

    /* ======= AUXILLIARY ======= */

    function recoverLostToken(address _token) external returns (bool) {
        require(_token != TIFO);
        require(_token != principle);
        IERC20(_token).safeTransfer(
            DAO,
            IERC20(_token).balanceOf(address(this))
        );
        return true;
    }

    function setMinBondPrice(uint256 _newPrice) external onlyOwner {
        uint256 oldPrice = terms.minimumPrice;
        terms.minimumPrice = _newPrice;
        emit SetMinBondPrice(msg.sender, oldPrice, _newPrice);
    }

    function setBCV(uint256 _newBCV) external onlyOwner {
        uint256 oldBCV = terms.controlVariable;
        terms.controlVariable = _newBCV;
        emit SetBCV(msg.sender, oldBCV, _newBCV);
    }

    function setVestingTerm(uint256 _newVestingTerm) external onlyOwner {
        uint256 oldVestingTerm = terms.vestingTerm;
        terms.vestingTerm = _newVestingTerm;
        emit SetVestingTerm(msg.sender, oldVestingTerm, _newVestingTerm);
    }

    function setDao(address _dao) external onlyOwner {
        DAO = _dao;
    }

    function setPriceBase(uint256 _priceBase) external onlyOwner {
        priceBase = _priceBase;
    }


    function defaultRebaseRateInfoId() public view returns (uint256) {
        return IStakingConfig(stakingConfig).defaultRebaseRateInfoId();
    }


    function setContract(uint256 _type, address _contract) external onlyOwner {
        if (_type == 0) {
            stakingConfig = _contract;
        }
    }
}
