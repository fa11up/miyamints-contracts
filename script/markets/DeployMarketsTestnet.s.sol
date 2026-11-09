// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { MarketTypes } from "../../src/markets/MarketTypes.sol";
import { PredictionRegistry } from "../../src/markets/PredictionRegistry.sol";
import { MarketFactory } from "../../src/markets/MarketFactory.sol";
import { EligibilityGate } from "../../src/markets/EligibilityGate.sol";
import { UsdcDoor } from "../../src/markets/UsdcDoor.sol";
import { ExitDesk } from "../../src/markets/ExitDesk.sol";
import { DisputeModule } from "../../src/markets/DisputeModule.sol";
import { SwarmResolver } from "../../src/markets/SwarmResolver.sol";
import { CouncilResolver } from "../../src/markets/CouncilResolver.sol";
import { IPredictionRegistry } from "../../src/markets/interfaces/IMarkets.sol";
import { MockImdUSD, MockUSDC } from "../../test/markets/mocks/MarketMockTokens.sol";
import { MockUsdcSwapper, MockPegPriceFeed } from "../../test/markets/mocks/MarketMockOracles.sol";

/**
 * @title DeployMarketsTestnet
 * @notice Deploys the prediction-market system with MOCK imdUSD, MOCK USDC, a mock USDC->imdUSD swapper and a mock
 *         peg price feed, for a testnet (Sepolia by default). It refuses to run on Ethereum mainnet (1) and
 *         Robinhood Chain mainnet (4663): this system is not cleared for real money.
 *
 *         Dry run (no transactions sent):
 *           forge script script/markets/DeployMarketsTestnet.s.sol --rpc-url $SEPOLIA_RPC_URL
 *
 *         Every parameter is read from the environment with a testnet default:
 *           OWNER, TREASURY, RESOLVER_BUDGET, INSURANCE       (default: the broadcaster)
 *           KYC_SIGNER                                        (default: the broadcaster; mock eligibility signer)
 *           ORACLE_SIGNER                                     (default: the IdentityMD oracle service key)
 *           COUNCIL_MEMBERS (comma list), COUNCIL_THRESHOLD   (default: the broadcaster, 1)
 *           CREATOR, CREATOR_CREW (comma list)                (optional: registers one creator)
 *           WALLET_CAP, MARKET_CAP, MIN_STAKE (wei), LOCK_MARGIN (s)
 *           RAKE_TREASURY_BPS, RAKE_CREATOR_BPS, RAKE_RESOLVER_BPS, RAKE_INSURANCE_BPS
 *           MIN_BOND (wei), BOND_BPS, CREATOR_BOND (wei)
 *           PRIMARY_MIN_PANEL, PRIMARY_MIN_QUORUM, DISPUTE_MIN_PANEL, DISPUTE_MIN_QUORUM
 *           DESK_SEED_USDC (6 decimals), PRICE_MAX_AGE (s), MOCK_IMD_PRICE (1e18 = $1)
 *           PRIVATE_KEY                                       (optional; otherwise the default sender)
 */
contract DeployMarketsTestnet is Script {
    address internal constant SERVICE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes internal constant WINDOW_TAIL = '","v":1,"window":{"fromBlock":';

    struct Deployed {
        MockImdUSD imd;
        MockUSDC usdc;
        MockUsdcSwapper swapper;
        MockPegPriceFeed feed;
        PredictionRegistry registry;
        EligibilityGate gate;
        UsdcDoor door;
        ExitDesk desk;
        DisputeModule disputes;
        SwarmResolver primary;
        SwarmResolver dispute;
        CouncilResolver council;
        MarketFactory factory;
    }

    function run() external returns (Deployed memory d) {
        require(block.chainid != 1 && block.chainid != 4663, "NOT FOR MAINNET");

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        d.imd = new MockImdUSD();
        d.usdc = new MockUSDC();
        d.swapper = new MockUsdcSwapper(d.usdc, d.imd);
        d.feed = new MockPegPriceFeed();
        d.feed.setPrice(vm.envOr("MOCK_IMD_PRICE", uint256(1e18)));

        // The broadcaster owns everything while wiring; ownership moves to OWNER at the end.
        d.registry = new PredictionRegistry(deployer, address(d.imd), _config(deployer));
        IPredictionRegistry reg = IPredictionRegistry(address(d.registry));
        d.gate = new EligibilityGate(deployer, vm.envOr("KYC_SIGNER", deployer));
        d.door = new UsdcDoor(reg, address(d.usdc), address(d.imd), d.swapper);
        d.desk = new ExitDesk(
            deployer,
            reg,
            address(d.usdc),
            address(d.imd),
            d.door,
            d.feed,
            uint64(vm.envOr("PRICE_MAX_AGE", uint256(1 hours)))
        );
        d.disputes = new DisputeModule(reg);
        address oracle = vm.envOr("ORACLE_SIGNER", SERVICE_SIGNER);
        d.primary = new SwarmResolver(
            reg,
            oracle,
            SwarmResolver.Tier.Primary,
            uint16(vm.envOr("PRIMARY_MIN_PANEL", uint256(25))),
            uint16(vm.envOr("PRIMARY_MIN_QUORUM", uint256(13)))
        );
        d.dispute = new SwarmResolver(
            reg,
            oracle,
            SwarmResolver.Tier.Dispute,
            uint16(vm.envOr("DISPUTE_MIN_PANEL", uint256(100))),
            uint16(vm.envOr("DISPUTE_MIN_QUORUM", uint256(67)))
        );
        address[] memory one = new address[](1);
        one[0] = deployer;
        d.council = new CouncilResolver(
            vm.envOr("COUNCIL_MEMBERS", ",", one), uint8(vm.envOr("COUNCIL_THRESHOLD", uint256(1)))
        );
        d.factory = new MarketFactory(d.registry);

        d.registry
            .setModules(
                address(d.door),
                address(d.gate),
                address(d.desk),
                address(d.disputes),
                address(d.dispute),
                address(d.council)
            );
        d.registry.setFactory(address(d.factory));
        d.registry.setResolver(address(d.primary), true);
        d.registry.addTemplate(_winnerTemplate());
        d.registry.addTemplate(_milestoneTemplate());

        address creator = vm.envOr("CREATOR", address(0));
        if (creator != address(0)) {
            d.registry.setCreator(creator, true, vm.envOr("CREATOR_CREW", ",", new address[](0)));
        }

        uint256 seed = vm.envOr("DESK_SEED_USDC", uint256(25_000e6));
        if (seed != 0) {
            d.usdc.mint(deployer, seed);
            d.usdc.approve(address(d.desk), seed);
            d.desk.fund(seed);
        }

        address owner = vm.envOr("OWNER", deployer);
        if (owner != deployer) {
            d.registry.transferOwnership(owner);
            d.gate.transferOwnership(owner);
            d.desk.transferOwnership(owner);
        }
        vm.stopBroadcast();

        _log(d, owner);
    }

    function _config(address deployer) internal view returns (PredictionRegistry.Config memory c) {
        c.treasury = vm.envOr("TREASURY", deployer);
        c.resolverBudget = vm.envOr("RESOLVER_BUDGET", deployer);
        c.insurance = vm.envOr("INSURANCE", deployer);
        c.rake = MarketTypes.RakeSplit({
            treasuryBps: uint16(vm.envOr("RAKE_TREASURY_BPS", uint256(100))),
            creatorBps: uint16(vm.envOr("RAKE_CREATOR_BPS", uint256(75))),
            resolverBps: uint16(vm.envOr("RAKE_RESOLVER_BPS", uint256(50))),
            insuranceBps: uint16(vm.envOr("RAKE_INSURANCE_BPS", uint256(25)))
        });
        c.perWalletCap = uint128(vm.envOr("WALLET_CAP", uint256(250e18)));
        c.perMarketCap = uint128(vm.envOr("MARKET_CAP", uint256(10_000e18)));
        c.minStake = uint128(vm.envOr("MIN_STAKE", uint256(1e18)));
        c.minBond = uint128(vm.envOr("MIN_BOND", uint256(50e18)));
        c.bondBps = uint16(vm.envOr("BOND_BPS", uint256(200)));
        c.creatorBond = uint128(vm.envOr("CREATOR_BOND", uint256(0)));
        c.lockMargin = uint32(vm.envOr("LOCK_MARGIN", uint256(180)));
    }

    function _gameParts(bytes memory head, bytes memory ask) internal pure returns (bytes[] memory p) {
        p = new bytes[](4);
        p[0] = head;
        p[1] = ": ";
        p[2] = " (away) at ";
        p[3] = bytes.concat(" (home). ", ask, WINDOW_TAIL);
    }

    /// @dev Two-way game winner. Codes: 1 home, 2 away, 3 draw, 4 postponed > 48 h, 5 abandoned; 3-5 void.
    function _winnerTemplate() internal pure returns (MarketTypes.Template memory t) {
        t.name = "game.winner.2way";
        t.parts = _gameParts(
            '{"answerType":"uint256","chainId":1,"definitions":{"codes":"Answer with one code: 1 = the home team won, 2 = the away team won, 3 = draw, 4 = postponed and not completed within 48 hours of the scheduled start, 5 = abandoned with no official result.","scope":"Final result including overtime, as officially recorded by the league."},"question":"',
            "Which side won the game, overtime included?"
        );
        t.startParts = _gameParts(
            '{"answerType":"uint256","chainId":1,"definitions":{"scope":"The official start time recorded by the league, in unix seconds."},"question":"',
            "At what time did the game officially start, in unix seconds?"
        );
        t.slotCount = 3;
        t.outcomeCount = 2;
        t.answerMode = MarketTypes.AnswerMode.Coded;
        t.answerType = MarketTypes.ANSWER_UINT256;
        t.codeMap = hex"000102000000";
        t.dataChainId = 1;
        t.disputeWindow = 2 hours;
        t.minLockGap = 0;
    }

    /// @dev Creator milestone, success side only. Locks at least 24 h before the deadline.
    function _milestoneTemplate() internal pure returns (MarketTypes.Template memory t) {
        t.name = "creator.milestone.followers";
        t.parts = new bytes[](4);
        t.parts[0] =
            '{"answerType":"bool","chainId":1,"definitions":{"scope":"Count as shown by the platform public page and one independent tracker."},"question":"Does the Kick channel ';
        t.parts[1] = " have at least ";
        t.parts[2] = " followers at ";
        t.parts[3] = bytes.concat("?", WINDOW_TAIL);
        t.slotCount = 3;
        t.outcomeCount = 2;
        t.answerMode = MarketTypes.AnswerMode.Bool;
        t.answerType = MarketTypes.ANSWER_BOOL;
        t.dataChainId = 1;
        t.disputeWindow = 24 hours;
        t.minLockGap = 24 hours;
    }

    function _log(Deployed memory d, address owner) internal pure {
        console2.log("chain: testnet only; owner", owner);
        console2.log("MockImdUSD        ", address(d.imd));
        console2.log("MockUSDC          ", address(d.usdc));
        console2.log("MockUsdcSwapper   ", address(d.swapper));
        console2.log("MockPegPriceFeed  ", address(d.feed));
        console2.log("PredictionRegistry", address(d.registry));
        console2.log("EligibilityGate   ", address(d.gate));
        console2.log("UsdcDoor          ", address(d.door));
        console2.log("ExitDesk          ", address(d.desk));
        console2.log("DisputeModule     ", address(d.disputes));
        console2.log("SwarmResolver (1) ", address(d.primary));
        console2.log("SwarmResolver (2) ", address(d.dispute));
        console2.log("CouncilResolver   ", address(d.council));
        console2.log("MarketFactory     ", address(d.factory));
    }
}
