// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

error INVALID_TIER();
error ALREADY_SUBBED();
error NOT_SUBBED();
error NOT_OWNER();
error NOT_OWNER_OR_WHITELISTED();

contract LlamaSubsFlatRateERC20 {
    using SafeTransferLib for ERC20;

    struct Tier {
        uint128 costPerPeriod;
        uint88 amountOfSubs;
        uint40 disabledAt;
    }

    struct User {
        uint216 tier;
        uint40 expires;
    }

    address public immutable owner;
    address public immutable token;
    uint256 public currentPeriod;
    uint256 public periodDuration;
    uint256 public claimable;
    uint256 public numOfTiers;
    uint256[] public activeTiers;
    mapping(uint256 => Tier) public tiers;
    mapping(uint256 => mapping(uint256 => uint256)) public subsToExpire;
    mapping(address => User) public users;
    mapping(address => uint256) public whitelist;

    event Subscribe(
        address indexed subscriber,
        uint256 tier,
        uint256 durations,
        uint256 expires,
        uint256 sent
    );
    event Unsubscribe(address indexed subscriber, uint256 refund);
    event Claim(address caller, address to, uint256 amount);
    event AddTier(uint256 tierNumber, uint128 costPerPeriod);
    event RemoveTier(uint256 tierNumber);
    event AddWhitelist(address toAdd);
    event RemoveWhitelist(address toRemove);

    constructor(
        address _owner,
        address _token,
        uint256 _currentPeriod,
        uint256 _periodDuration
    ) {
        owner = _owner;
        token = _token;
        currentPeriod = _currentPeriod;
        periodDuration = _periodDuration;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NOT_OWNER();
        _;
    }

    function subscribe(
        address subscriber,
        uint256 _tier,
        uint256 _durations
    ) external {
        Tier storage tier = tiers[_tier];
        if (tier.disabledAt > 0 || tier.costPerPeriod == 0)
            revert INVALID_TIER();
        _update();

        User storage user = users[subscriber];
        uint256 expires;
        uint256 nextPeriod;
        uint256 actualDurations;
        uint256 claimableThisPeriod;
        unchecked {
            nextPeriod = currentPeriod + periodDuration;
            actualDurations = _durations - 1;
            expires =
                uint256(user.expires) +
                (actualDurations * periodDuration);
            if (user.expires > currentPeriod) {
                subsToExpire[user.tier][user.expires]--;
            }
            if (nextPeriod > user.expires) {
                claimableThisPeriod =
                    (tier.costPerPeriod * block.timestamp) /
                    nextPeriod;
            }
            subsToExpire[user.tier][expires]++;
        }
        uint256 sendToContract = claimableThisPeriod +
            (actualDurations * uint256(tier.costPerPeriod));
        claimable += claimableThisPeriod;
        users[subscriber] = User({
            tier: uint216(_tier),
            expires: uint40(expires)
        });
        ERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            sendToContract
        );
        emit Subscribe(subscriber, _tier, _durations, expires, sendToContract);
    }

    function unsubscribe() external {
        User storage user = users[msg.sender];
        if (user.expires == 0) revert NOT_SUBBED();
        _update();

        Tier storage tier = tiers[user.tier];
        uint256 refund;
        uint256 nextPeriod;
        unchecked {
            nextPeriod = currentPeriod + periodDuration;
            if (tier.disabledAt > 0 && user.expires > tier.disabledAt) {
                refund =
                    ((uint256(user.expires) - uint256(tier.disabledAt)) *
                        uint256(tier.costPerPeriod)) /
                    periodDuration;
            } else if (user.expires > nextPeriod) {
                refund =
                    ((uint256(user.expires) - nextPeriod) *
                        uint256(tier.costPerPeriod)) /
                    periodDuration;
                subsToExpire[user.tier][user.expires]--;
                tiers[user.tier].amountOfSubs--;
            }
        }
        delete users[msg.sender];
        ERC20(token).safeTransfer(msg.sender, refund);
        emit Unsubscribe(msg.sender, refund);
    }

    function claim(uint256 _amount) external {
        if (msg.sender != owner && whitelist[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        _update();
        claimable -= _amount;
        ERC20(token).safeTransfer(owner, _amount);
        emit Claim(msg.sender, owner, _amount);
    }

    function addTier(uint128 _costPerPeriod) external onlyOwner {
        _update();
        uint256 tierNumber = numOfTiers;
        tiers[tierNumber].costPerPeriod = _costPerPeriod;
        activeTiers.push(tierNumber);
        unchecked {
            numOfTiers++;
        }
        emit AddTier(tierNumber, _costPerPeriod);
    }

    function removeTier(uint256 _tier) external onlyOwner {
        _update();
        uint256 len = activeTiers.length;
        uint256 last = activeTiers[len - 1];
        uint256 i = 0;
        while (activeTiers[i] != _tier) {
            unchecked {
                i++;
            }
        }
        uint256 nextPeriod;
        unchecked {
            nextPeriod = currentPeriod + periodDuration;
        }
        claimable +=
            uint256(tiers[_tier].costPerPeriod) *
            uint256(tiers[_tier].amountOfSubs);

        tiers[_tier].disabledAt = uint40(nextPeriod);
        activeTiers[i] = last;
        activeTiers.pop();
        emit RemoveTier(_tier);
    }

    function addWhitelist(address _toAdd) external onlyOwner {
        whitelist[_toAdd] = 1;
        emit AddWhitelist(_toAdd);
    }

    function removeWhitelist(address _toRemove) external onlyOwner {
        whitelist[_toRemove] = 0;
        emit RemoveWhitelist(_toRemove);
    }

    function _update() private {
        /// This will save gas since u only update storage at the end
        uint256 newCurrentPeriod = currentPeriod;
        uint256 newClaimable = claimable;

        uint256 len = activeTiers.length;
        while (block.timestamp > newCurrentPeriod) {
            uint256 i = 0;
            while (i < len) {
                uint256 curr = activeTiers[i];
                Tier storage tier = tiers[curr];
                newClaimable +=
                    uint256(tier.amountOfSubs) *
                    uint256(tier.costPerPeriod);
                unchecked {
                    tiers[curr].amountOfSubs -= uint88(
                        subsToExpire[curr][newCurrentPeriod]
                    );
                }
                /// Free up storage
                delete subsToExpire[curr][newCurrentPeriod];
                unchecked {
                    i++;
                }
            }
            unchecked {
                /// Go to next period
                newCurrentPeriod += periodDuration;
            }
        }
        currentPeriod = newCurrentPeriod;
        claimable = newClaimable;
    }
}
