// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MarketTypes } from "./MarketTypes.sol";
import { IParimutuelMarket, IResolver } from "./interfaces/IMarkets.sol";

/**
 * @title CouncilResolver
 * @notice The last-resort human council for escalated markets: a fixed member set with a vote threshold
 *         (e.g. 3 of 5). Members vote on chain. When `threshold` members back the same outcome for a market,
 *         the market settles to it.
 *
 *         The council can only:
 *         - pick one of the market's coded outcomes or VOID (0), and only while the market is Escalated and
 *           within the market's 7-day council window (after that anyone voids the market);
 *         - slash a creator's escrowed fee share and bond to the insurance reserve.
 *         It cannot redirect stakes. Members and threshold are fixed at deployment; a new council is a new
 *         contract that only FUTURE markets snapshot.
 */
contract CouncilResolver is IResolver {
    uint256 public constant MAX_MEMBERS = 9;

    struct Result {
        bool answered;
        uint8 outcome;
    }

    uint8 public immutable threshold;
    address[] internal _members;
    mapping(address => bool) public isMember;

    /// @dev vote + 1 per member per market (0 = no vote), so a member can change an unexecuted vote.
    mapping(address market => mapping(address member => uint16)) internal _vote;
    mapping(address market => mapping(uint8 outcome => uint8)) public votesFor;
    mapping(address market => mapping(address member => bool)) public slashVoted;
    mapping(address market => uint8) public slashVotes;
    mapping(address market => Result) internal _results;

    event Voted(address indexed market, address indexed member, uint8 outcome, uint8 votes);
    event Decided(address indexed market, uint8 outcome);
    event SlashVoted(address indexed market, address indexed member, uint8 votes);
    event Slashed(address indexed market);

    error InvalidConfiguration();
    error NotMember();
    error NotEscalated();
    error InvalidOutcome();
    error AlreadyDecided();
    error AlreadyVoted();

    constructor(address[] memory members_, uint8 threshold_) {
        uint256 n = members_.length;
        if (n == 0 || n > MAX_MEMBERS || threshold_ == 0 || threshold_ > n || uint256(threshold_) * 2 <= n) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < n; ++i) {
            address m = members_[i];
            if (m == address(0) || isMember[m]) revert InvalidConfiguration();
            isMember[m] = true;
        }
        _members = members_;
        threshold = threshold_;
    }

    function members() external view returns (address[] memory) {
        return _members;
    }

    /// @inheritdoc IResolver
    function result(address market) external view returns (bool answered, uint8 outcome, uint64 attestedStart) {
        Result storage r = _results[market];
        return (r.answered, r.outcome, 0);
    }

    /// @notice Vote for `outcome` (1..outcomeCount, or 0 = VOID) on an escalated market.
    function vote(address market, uint8 outcome) external {
        if (!isMember[msg.sender]) revert NotMember();
        if (_results[market].answered) revert AlreadyDecided();
        IParimutuelMarket m = IParimutuelMarket(market);
        if (m.state() != MarketTypes.State.Escalated) revert NotEscalated();
        if (outcome > m.terms().outcomeCount) revert InvalidOutcome();

        uint16 prev = _vote[market][msg.sender];
        if (prev != 0) {
            if (prev - 1 == outcome) revert AlreadyVoted();
            --votesFor[market][uint8(prev - 1)];
        }
        _vote[market][msg.sender] = uint16(outcome) + 1;
        uint8 count = ++votesFor[market][outcome];
        emit Voted(market, msg.sender, outcome, count);

        if (count >= threshold) {
            _results[market] = Result(true, outcome);
            emit Decided(market, outcome);
            m.councilResolve(outcome);
        }
    }

    /// @notice Vote to slash `market`'s creator.
    function voteSlash(address market) external {
        if (!isMember[msg.sender]) revert NotMember();
        if (slashVoted[market][msg.sender]) revert AlreadyVoted();
        slashVoted[market][msg.sender] = true;
        uint8 count = ++slashVotes[market];
        emit SlashVoted(market, msg.sender, count);
        if (count == threshold) {
            emit Slashed(market);
            IParimutuelMarket(market).slashCreator();
        }
    }
}
