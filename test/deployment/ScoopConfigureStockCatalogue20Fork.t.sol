// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";

contract ScoopConfigureStockCatalogue20ForkTest is Test {
    ScoopQuoteRegistry constant REGISTRY = ScoopQuoteRegistry(0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD);

    ScoopPriceOracle constant ORACLE = ScoopPriceOracle(0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12);

    address constant AUTHORITY = 0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7;

    address constant ETH = 0x0000000000000000000000000000000000000000;

    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint48 constant STOCK_MAX_AGE = 345_600;

    struct Stock {
        string symbol;
        address token;
        address feed;
    }

    function setUp() public {
        // Pin immediately before AAPL oracle configuration (tx at block 56_711_113).
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), 56_711_112);
        require(block.chainid == 4663, "wrong chain");
    }

    function test_configureFinal20StockCatalogue() public {
        Stock[20] memory stocks = _stocks();

        // Baseline invariants
        assertTrue(REGISTRY.isRegistered(ETH));
        assertTrue(REGISTRY.isEnabled(ETH));
        assertTrue(ORACLE.isConfigured(ETH));
        assertTrue(ORACLE.isEnabled(ETH));

        assertTrue(REGISTRY.isRegistered(USDG));
        assertTrue(REGISTRY.isEnabled(USDG));
        assertTrue(ORACLE.isConfigured(USDG));
        assertTrue(ORACLE.isEnabled(USDG));

        ScoopPriceOracle.PriceFeedConfig memory ethBefore = ORACLE.getFeedConfig(ETH);

        ScoopPriceOracle.PriceFeedConfig memory usdgBefore = ORACLE.getFeedConfig(USDG);

        vm.startPrank(AUTHORITY);

        for (uint256 i = 0; i < stocks.length; i++) {
            Stock memory s = stocks[i];

            assertFalse(REGISTRY.isRegistered(s.token));
            assertFalse(ORACLE.isConfigured(s.token));

            // TX1 equivalent: oracle first
            ORACLE.configureFeed(s.token, s.feed, STOCK_MAX_AGE);

            assertTrue(ORACLE.isConfigured(s.token));
            assertTrue(ORACLE.isEnabled(s.token));

            ScoopPriceOracle.PriceFeedConfig memory cfg = ORACLE.getFeedConfig(s.token);

            assertEq(cfg.feed, s.feed);
            assertEq(cfg.maxAge, STOCK_MAX_AGE);
            assertEq(cfg.feedDecimals, 8);
            assertTrue(cfg.enabled);

            uint256 priceUsd = ORACLE.getPriceUsd(s.token);
            assertGt(priceUsd, 0);

            // TX2 equivalent: register only after oracle is healthy
            REGISTRY.registerQuote(s.token, ScoopQuoteRegistry.QuoteType.Stock);

            assertTrue(REGISTRY.isRegistered(s.token));
            assertTrue(REGISTRY.isEnabled(s.token));
            assertEq(uint8(REGISTRY.quoteType(s.token)), uint8(ScoopQuoteRegistry.QuoteType.Stock));

            console2.log("CONFIGURED", s.symbol);
            console2.log("priceUsd", priceUsd);
        }

        vm.stopPrank();

        // ETH unchanged
        ScoopPriceOracle.PriceFeedConfig memory ethAfter = ORACLE.getFeedConfig(ETH);

        assertEq(ethAfter.feed, ethBefore.feed);
        assertEq(ethAfter.maxAge, ethBefore.maxAge);
        assertEq(ethAfter.feedDecimals, ethBefore.feedDecimals);
        assertEq(ethAfter.enabled, ethBefore.enabled);

        assertTrue(REGISTRY.isRegistered(ETH));
        assertTrue(REGISTRY.isEnabled(ETH));

        // USDG unchanged
        ScoopPriceOracle.PriceFeedConfig memory usdgAfter = ORACLE.getFeedConfig(USDG);

        assertEq(usdgAfter.feed, usdgBefore.feed);
        assertEq(usdgAfter.maxAge, usdgBefore.maxAge);
        assertEq(usdgAfter.feedDecimals, usdgBefore.feedDecimals);
        assertEq(usdgAfter.enabled, usdgBefore.enabled);

        assertTrue(REGISTRY.isRegistered(USDG));
        assertTrue(REGISTRY.isEnabled(USDG));
    }

    function _stocks() internal pure returns (Stock[20] memory s) {
        s[0] = Stock("AAPL", 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0);
        s[1] = Stock("AMD", 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72);
        s[2] = Stock("AMZN", 0x12f190a9F9d7D37a250758b26824B97CE941bF54, 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C);
        s[3] = Stock("ASML", 0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA, 0xB4106147E8cce40b7d46124090d373A71b70f87D);
        s[4] = Stock("BABA", 0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4, 0x62Cc8F9b5f56a33c9C8A60c8B92779f523c4E984);
        s[5] = Stock("COIN", 0x6330D8C3178a418788dF01a47479c0ce7CCF450b, 0xA3a468A452940B7D6b69991207B508c609a98Ef2);
        s[6] = Stock("CRCL", 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5, 0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a);
        s[7] = Stock("GME", 0x1b0E319c6A659F002271B69dB8A7df2F911c153E, 0x27C71df6A64fB476468EdF256CF72c038baB5B67);
        s[8] = Stock("GOOGL", 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 0xF6f373a037c30F0e5010d854385cA89185AE638b);
        s[9] = Stock("INTC", 0xc72b96e0E48ecd4DC75E1e45396e26300BC39681, 0x3f390C5C24628Ac7C489515402235FeAD71D1913);
        s[10] = Stock("META", 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, 0x7C38C00C30BEe9378381E7B6135d7283356D71b1);
        s[11] = Stock("MSFT", 0xe93237C50D904957Cf27E7B1133b510C669c2e74, 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E);
        s[12] = Stock("MSTR", 0xec262a75e413fAfD0dF80480274532C79D42da09, 0x396118bdFB181e6240E74D243F266B061c0edc3D);
        s[13] = Stock("MU", 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596);
        s[14] = Stock("NVDA", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15);
        s[15] = Stock("PLTR", 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c);
        s[16] = Stock("SNDK", 0xB90A19fF0Af67f7779afF50A882A9CfF42446400, 0xfb133Fa4B7b385802B693a293606682Df47109A3);
        s[17] = Stock("SPCX", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb);
        s[18] = Stock("TSLA", 0x322F0929c4625eD5bAd873c95208D54E1c003b2d, 0x4A1166a659A55625345e9515b32adECea5547C38);
        s[19] = Stock("TSM", 0x58FfE4a942d3885bAa22D7520691F611EF09e7AA, 0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F);
    }
}
