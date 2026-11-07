// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {AgentGatewayAccount} from "../src/bufi/agent-policy/AgentGatewayAccount.sol";
import {AgentGatewayAccountFactory} from "../src/bufi/agent-policy/AgentGatewayAccountFactory.sol";
import {AgentGatewayAccountFactoryArcTestnet} from "../src/bufi/agent-policy/AgentGatewayAccountFactoryArcTestnet.sol";
import {GatewayIntentPolicy} from "../src/bufi/gateway-guard/GatewayIntentPolicy.sol";
import {Test} from "forge-std/Test.sol";

contract AgentGatewayAccountFactoryTest is Test {
    address internal constant ARC_TESTNET_SAFE = 0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B;
    address internal constant ARC_TESTNET_IDENTITY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant ARC_TESTNET_GATEWAY = 0x0077777d7EBA4688BDeF3E311b846F25870A19B9;
    address internal constant INITIAL_ISSUER = 0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474;

    function setUp() public {
        vm.chainId(5042002);
        vm.etch(ARC_TESTNET_SAFE, hex"600080fd");
        vm.etch(ARC_TESTNET_IDENTITY, hex"600080fd");
        vm.etch(ARC_TESTNET_GATEWAY, hex"600080fd");
    }

    function test_arcTestnetFactory_deploys_and_authorizes_initial_issuer() public {
        AgentGatewayAccountFactoryArcTestnet factory =
            new AgentGatewayAccountFactoryArcTestnet(ARC_TESTNET_SAFE, INITIAL_ISSUER);
        assertEq(factory.administrator(), ARC_TESTNET_SAFE);
        assertEq(factory.identityRegistry(), ARC_TESTNET_IDENTITY);
        assertEq(factory.gatewayWallet(), ARC_TESTNET_GATEWAY);
        assertEq(factory.accountCreationCodeHash(), keccak256(type(AgentGatewayAccount).creationCode));
        assertTrue(factory.issuers(INITIAL_ISSUER));
    }

    function test_arcTestnetFactory_refuses_invalid_bootstrap_args() public {
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        new AgentGatewayAccountFactoryArcTestnet(ARC_TESTNET_SAFE, address(0));

        address otherAdmin = address(0xBEEF);
        vm.etch(otherAdmin, hex"600080fd");
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        new AgentGatewayAccountFactoryArcTestnet(otherAdmin, INITIAL_ISSUER);
    }

    function test_setIssuer_requires_administrator() public {
        AgentGatewayAccountFactoryArcTestnet factory =
            new AgentGatewayAccountFactoryArcTestnet(ARC_TESTNET_SAFE, INITIAL_ISSUER);
        address nextIssuer = address(0xCAFE);

        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.setIssuer(nextIssuer, true);

        vm.prank(ARC_TESTNET_SAFE);
        factory.setIssuer(nextIssuer, true);
        assertTrue(factory.issuers(nextIssuer));
    }

    function test_F26_gatewayDomainSeparatorUsesFixedNameAndVersionOnly() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version)"),
                keccak256(bytes("GatewayWallet")),
                keccak256(bytes("1"))
            )
        );
        assertEq(expected, GatewayIntentPolicy.GATEWAY_DOMAIN_SEPARATOR);
        assertEq(expected, 0x23a37920eca61226c76d13c4462857a362147e4b18da665dba894fa297ae4f34);
        bytes32 chainBound = GatewayIntentPolicy.chainBoundDomainSeparator(block.chainid, ARC_TESTNET_GATEWAY);
        assertTrue(chainBound != expected);
    }

    function test_F27_tryRecoverChecksErrorArgAndEpochChangedIndexesAgent() public {
        AgentGatewayAccount.Route[] memory emptyRoutes = new AgentGatewayAccount.Route[](0);
        address ownerKey = vm.addr(0xA11CE);
        address agentKey = vm.addr(0xB0B);
        AgentGatewayAccount account = new AgentGatewayAccount(
            ownerKey, agentKey, ARC_TESTNET_IDENTITY, 1, ARC_TESTNET_GATEWAY, 26, 100, address(0), emptyRoutes
        );

        bytes4 magic = account.isValidSignature(keccak256("digest"), hex"1234");
        assertEq(magic, bytes4(0xffffffff));
    }

    function test_SafeTxBuilder_Arc5042_And_Testnet_AgentGatewayAccountFactory() public {
        address create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        vm.prank(ARC_TESTNET_SAFE);
        (bool okTestnet, bytes memory rTestnet) = create2Factory.call(
            abi.encodePacked(
                keccak256("bufi.agent-gateway-account-factory.v1"),
                type(AgentGatewayAccountFactory).creationCode,
                abi.encode(ARC_TESTNET_SAFE)
            )
        );
        assertTrue(okTestnet);
        AgentGatewayAccountFactory testnetFactory = AgentGatewayAccountFactory(address(bytes20(rTestnet)));
        assertEq(address(testnetFactory), 0xbeF3d87dB69490115a8B83512E1e1D0e2e38D7f9);
        vm.prank(ARC_TESTNET_SAFE);
        testnetFactory.setIssuer(INITIAL_ISSUER, true);
        assertTrue(testnetFactory.issuers(INITIAL_ISSUER));

        address mainnetSafe = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09;
        address mainnetIdentity = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
        address mainnetGateway = 0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE;
        vm.chainId(5042);
        vm.etch(mainnetSafe, hex"600080fd");
        vm.etch(mainnetIdentity, hex"600080fd");
        vm.etch(mainnetGateway, hex"600080fd");

        vm.prank(mainnetSafe);
        (bool okMainnet, bytes memory rMainnet) = create2Factory.call(
            abi.encodePacked(
                keccak256("bufi.agent-gateway-account-factory.v1"),
                type(AgentGatewayAccountFactory).creationCode,
                abi.encode(mainnetSafe)
            )
        );
        assertTrue(okMainnet);
        AgentGatewayAccountFactory mainnetFactory = AgentGatewayAccountFactory(address(bytes20(rMainnet)));
        assertEq(address(mainnetFactory), 0xC4c3886A7f66E49fF95d7A15a12958b4cBa0eA3C);
        vm.prank(mainnetSafe);
        mainnetFactory.setIssuer(INITIAL_ISSUER, true);
        assertTrue(mainnetFactory.issuers(INITIAL_ISSUER));
    }
}
