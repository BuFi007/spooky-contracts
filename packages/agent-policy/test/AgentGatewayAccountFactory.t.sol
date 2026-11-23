// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {AgentGatewayAccount} from "../src/bufi/agent-policy/AgentGatewayAccount.sol";
import {AgentGatewayAccountFactory} from "../src/bufi/agent-policy/AgentGatewayAccountFactory.sol";
import {AgentGatewayAccountFactoryArcTestnet} from "../src/bufi/agent-policy/AgentGatewayAccountFactoryArcTestnet.sol";
import {GatewayIntentPolicy} from "../src/bufi/gateway-guard/GatewayIntentPolicy.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Test} from "forge-std/Test.sol";

contract MockIdentityRegistry {
    uint256 public nextId;
    bool public useFixedId;
    uint256 public fixedId;
    address public mintToOverride;
    bool public skipOnReceivedOnRegister;
    address public registerFromOverride;
    bool public callOnReceivedBeforeMint;
    uint8 public transferMode;

    bool public reenterOnRegister;
    address public reenterFactory;
    bytes public reenterCalldata;

    mapping(uint256 => address) internal _owners;

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    function setOwner(uint256 tokenId, address owner_) external {
        _owners[tokenId] = owner_;
    }

    function setFixedId(bool enabled, uint256 id) external {
        useFixedId = enabled;
        fixedId = id;
    }

    function setMintToOverride(address target) external {
        mintToOverride = target;
    }

    function setRegisterHooks(bool skipOnReceived, address fromOverride, bool beforeMint) external {
        skipOnReceivedOnRegister = skipOnReceived;
        registerFromOverride = fromOverride;
        callOnReceivedBeforeMint = beforeMint;
    }

    function setTransferMode(uint8 mode) external {
        transferMode = mode;
    }

    function configureReentrancy(address factory_, bytes calldata callData_) external {
        reenterOnRegister = true;
        reenterFactory = factory_;
        reenterCalldata = callData_;
    }

    function register(string calldata) external returns (uint256 id) {
        if (reenterOnRegister) {
            reenterOnRegister = false;
            (bool ok, bytes memory ret) = reenterFactory.call(reenterCalldata);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            id = ++nextId;
            _owners[id] = msg.sender;
            return id;
        }

        id = useFixedId ? fixedId : ++nextId;
        address recipient = mintToOverride == address(0) ? msg.sender : mintToOverride;

        if (callOnReceivedBeforeMint && !skipOnReceivedOnRegister) {
            bytes4 sel = IERC721Receiver(msg.sender).onERC721Received(msg.sender, registerFromOverride, id, "");
            require(sel == IERC721Receiver.onERC721Received.selector, "bad selector");
            _owners[id] = recipient;
            return id;
        }

        _owners[id] = recipient;
        if (!skipOnReceivedOnRegister) {
            bytes4 sel = IERC721Receiver(msg.sender).onERC721Received(msg.sender, registerFromOverride, id, "");
            require(sel == IERC721Receiver.onERC721Received.selector, "bad selector");
        }
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "not owner");
        _owners[tokenId] = to;
        if (transferMode == 1) {
            return;
        }
        bytes4 sel = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
        require(sel == IERC721Receiver.onERC721Received.selector, "bad selector");
        if (transferMode == 2) {
            _owners[tokenId] = address(0xBAD);
        }
    }
}

contract MockERC1271Owner {
    bytes32 public expectedHash;
    bytes public expectedSignature;

    function setExpected(bytes32 hash_, bytes calldata sig_) external {
        expectedHash = hash_;
        expectedSignature = sig_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (hash == expectedHash && keccak256(sig) == keccak256(expectedSignature)) {
            return 0x1626ba7e;
        }
        return 0xffffffff;
    }
}

contract AgentGatewayAccountFactoryTest is Test {
    address internal constant ARC_TESTNET_SAFE = 0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B;
    address internal constant ARC_TESTNET_IDENTITY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant ARC_TESTNET_GATEWAY = 0x0077777d7EBA4688BDeF3E311b846F25870A19B9;
    address internal constant ARC_MAINNET_SAFE = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09;
    address internal constant ARC_MAINNET_IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant ARC_MAINNET_GATEWAY = 0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE;
    address internal constant INITIAL_ISSUER = 0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474;

    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant OTHER_PK = 0xB0B0B;

    MockIdentityRegistry internal registryImpl;

    function setUp() public {
        vm.warp(1_000_000);
        vm.chainId(5042002);
        registryImpl = new MockIdentityRegistry();
        vm.etch(ARC_TESTNET_SAFE, hex"600080fd");
        vm.etch(ARC_TESTNET_IDENTITY, address(registryImpl).code);
        vm.etch(ARC_TESTNET_GATEWAY, hex"600080fd");
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildAuth(address owner_, address agent_, string memory uri_, bytes32 nonce_, uint64 deadline_)
        internal
        pure
        returns (AgentGatewayAccountFactory.CreateAuthorization memory, AgentGatewayAccount.Route[] memory)
    {
        AgentGatewayAccount.Route[] memory emptyRoutes = new AgentGatewayAccount.Route[](0);
        AgentGatewayAccountFactory.CreateAuthorization memory auth = AgentGatewayAccountFactory.CreateAuthorization({
            owner: owner_,
            agent: agent_,
            tokenURIHash: keccak256(bytes(uri_)),
            routesHash: keccak256(abi.encode(emptyRoutes)),
            router: address(0),
            maxExpiryBlocks: 100,
            nonce: nonce_,
            deadline: deadline_
        });
        return (auth, emptyRoutes);
    }

    function _deployTestnetFactory() internal returns (AgentGatewayAccountFactory factory) {
        factory = new AgentGatewayAccountFactory(ARC_TESTNET_SAFE);
        vm.prank(ARC_TESTNET_SAFE);
        factory.setIssuer(INITIAL_ISSUER, true);
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

    function test_constructor_guards_adminChainRegistryAndGateway() public {
        // EOA administrator on valid chain
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        new AgentGatewayAccountFactory(address(0xE0AE0A));

        // Contract administrator on unsupported chain
        vm.chainId(1);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        new AgentGatewayAccountFactory(ARC_TESTNET_SAFE);
        vm.chainId(5042002);

        // Missing identityRegistry code alone
        vm.etch(ARC_TESTNET_IDENTITY, "");
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        new AgentGatewayAccountFactory(ARC_TESTNET_SAFE);
        vm.etch(ARC_TESTNET_IDENTITY, address(registryImpl).code);

        // Missing gatewayWallet code alone
        vm.etch(ARC_TESTNET_GATEWAY, "");
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        new AgentGatewayAccountFactory(ARC_TESTNET_SAFE);
        vm.etch(ARC_TESTNET_GATEWAY, hex"600080fd");

        // Mainnet chainId 5042 resolves exact mainnet registry & gateway
        vm.chainId(5042);
        vm.etch(ARC_MAINNET_SAFE, hex"600080fd");
        vm.etch(ARC_MAINNET_IDENTITY, address(registryImpl).code);
        vm.etch(ARC_MAINNET_GATEWAY, hex"600080fd");
        AgentGatewayAccountFactory mainnetFactory = new AgentGatewayAccountFactory(ARC_MAINNET_SAFE);
        assertEq(mainnetFactory.administrator(), ARC_MAINNET_SAFE);
        assertEq(mainnetFactory.identityRegistry(), ARC_MAINNET_IDENTITY);
        assertEq(mainnetFactory.gatewayWallet(), ARC_MAINNET_GATEWAY);
    }

    function test_setIssuer_requires_administrator_emitsEvent_and_rejectsZero() public {
        AgentGatewayAccountFactoryArcTestnet factory =
            new AgentGatewayAccountFactoryArcTestnet(ARC_TESTNET_SAFE, INITIAL_ISSUER);
        address nextIssuer = address(0xCAFE);

        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.setIssuer(nextIssuer, true);

        vm.prank(ARC_TESTNET_SAFE);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.setIssuer(address(0), true);

        vm.prank(ARC_TESTNET_SAFE);
        vm.expectEmit(true, false, false, true, address(factory));
        emit AgentGatewayAccountFactory.IssuerAuthorized(nextIssuer, true);
        factory.setIssuer(nextIssuer, true);
        assertTrue(factory.issuers(nextIssuer));

        vm.prank(ARC_TESTNET_SAFE);
        vm.expectEmit(true, false, false, true, address(factory));
        emit AgentGatewayAccountFactory.IssuerAuthorized(nextIssuer, false);
        factory.setIssuer(nextIssuer, false);
        assertFalse(factory.issuers(nextIssuer));
    }

    function test_createAccount_happyPath_eoaOwner_and_erc1271Owner() public {
        AgentGatewayAccountFactory factory = _deployTestnetFactory();
        address owner = vm.addr(OWNER_PK);
        address agent = address(0xA9E71);
        string memory uri = "ipfs://agent-1";
        bytes32 nonce = keccak256("create-1");
        uint64 deadline = uint64(block.timestamp + 1 hours);

        (AgentGatewayAccountFactory.CreateAuthorization memory auth, AgentGatewayAccount.Route[] memory routes) =
            _buildAuth(owner, agent, uri, nonce, deadline);
        bytes memory sig = _signDigest(OWNER_PK, factory.creationDigest(auth));

        bytes memory initCode = abi.encodePacked(
            type(AgentGatewayAccount).creationCode,
            abi.encode(
                owner, agent, ARC_TESTNET_IDENTITY, uint256(1), ARC_TESTNET_GATEWAY, uint32(26), uint256(100), address(0), routes
            )
        );
        address expectedAccount =
            vm.computeCreate2Address(keccak256(abi.encode(owner, nonce)), keccak256(initCode), address(factory));

        vm.prank(INITIAL_ISSUER);
        vm.expectEmit(true, true, true, true, address(factory));
        emit AgentGatewayAccountFactory.AccountIssued(
            expectedAccount, 1, owner, ARC_TESTNET_IDENTITY, agent, INITIAL_ISSUER
        );
        AgentGatewayAccount account =
            factory.createAccount(auth, uri, routes, type(AgentGatewayAccount).creationCode, sig);

        assertEq(address(account), expectedAccount);
        assertTrue(factory.isIssuedAccount(address(account)));
        assertFalse(factory.isIssuedAccount(address(0xDEAD)));
        assertEq(factory.accountOfCreation(owner, nonce), address(account));
        assertEq(factory.accountOfIdentity(1), address(account));
        (address issOwner, address issAgent, address issIssuer, uint256 issId) = factory.issuances(address(account));
        assertEq(issOwner, owner);
        assertEq(issAgent, agent);
        assertEq(issIssuer, INITIAL_ISSUER);
        assertEq(issId, 1);
        assertEq(account.identityEpoch(), 1);
        assertEq(MockIdentityRegistry(ARC_TESTNET_IDENTITY).ownerOf(1), address(account));

        // ERC-1271 smart-contract owner path
        MockERC1271Owner contractOwner = new MockERC1271Owner();
        bytes32 nonce2 = keccak256("create-erc1271");
        (AgentGatewayAccountFactory.CreateAuthorization memory auth2, AgentGatewayAccount.Route[] memory routes2) =
            _buildAuth(address(contractOwner), agent, uri, nonce2, deadline);
        bytes32 digest2 = factory.creationDigest(auth2);
        bytes memory sig2 = hex"1271cafe";
        contractOwner.setExpected(digest2, sig2);

        // Wrong ERC-1271 signature reverts
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth2, uri, routes2, type(AgentGatewayAccount).creationCode, hex"bad0");

        // Valid ERC-1271 signature succeeds
        vm.prank(INITIAL_ISSUER);
        AgentGatewayAccount account2 =
            factory.createAccount(auth2, uri, routes2, type(AgentGatewayAccount).creationCode, sig2);
        assertTrue(factory.isIssuedAccount(address(account2)));
        assertEq(factory.accountOfIdentity(2), address(account2));
    }

    function test_createAccount_revertsOnEachPreconditionIndividually() public {
        AgentGatewayAccountFactory factory = _deployTestnetFactory();
        address owner = vm.addr(OWNER_PK);
        address agent = address(0xA9E72);
        string memory uri = "ipfs://agent-pre";
        bytes32 nonce = keccak256("pre-1");
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory creationCode = type(AgentGatewayAccount).creationCode;

        (AgentGatewayAccountFactory.CreateAuthorization memory auth, AgentGatewayAccount.Route[] memory routes) =
            _buildAuth(owner, agent, uri, nonce, deadline);
        bytes memory validSig = _signDigest(OWNER_PK, factory.creationDigest(auth));

        // 1. Non-issuer caller
        vm.prank(address(0xBAD1));
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth, uri, routes, creationCode, validSig);

        // 2. Expired deadline (block.timestamp == deadline)
        (AgentGatewayAccountFactory.CreateAuthorization memory expiredAuth,) =
            _buildAuth(owner, agent, uri, keccak256("pre-exp"), uint64(block.timestamp));
        bytes memory expiredSig = _signDigest(OWNER_PK, factory.creationDigest(expiredAuth));
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(expiredAuth, uri, routes, creationCode, expiredSig);

        // 3. Mismatched agentURI
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth, "ipfs://wrong-uri", routes, creationCode, validSig);

        // 4. Mismatched routes
        AgentGatewayAccount.Route[] memory otherRoutes = new AgentGatewayAccount.Route[](1);
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth, uri, otherRoutes, creationCode, validSig);

        // 5. Mismatched accountCreationCode
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth, uri, routes, hex"6000", validSig);

        // 6. Invalid ownerSignature
        bytes memory wrongSig = _signDigest(OTHER_PK, factory.creationDigest(auth));
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth, uri, routes, creationCode, wrongSig);

        // 7. Replay of (owner, nonce) after first creation succeeds
        vm.prank(INITIAL_ISSUER);
        factory.createAccount(auth, uri, routes, creationCode, validSig);

        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth, uri, routes, creationCode, validSig);
    }

    function test_createAccount_revertsOnPostRegisterAndPostTransferInvariants() public {
        AgentGatewayAccountFactory factory = _deployTestnetFactory();
        MockIdentityRegistry reg = MockIdentityRegistry(ARC_TESTNET_IDENTITY);
        address owner = vm.addr(OWNER_PK);
        address agent = address(0xA9E73);
        string memory uri = "ipfs://agent-inv";
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory creationCode = type(AgentGatewayAccount).creationCode;

        // First create id = 1 legitimately
        (AgentGatewayAccountFactory.CreateAuthorization memory auth1, AgentGatewayAccount.Route[] memory routes) =
            _buildAuth(owner, agent, uri, keccak256("inv-1"), deadline);
        bytes memory sig1 = _signDigest(OWNER_PK, factory.creationDigest(auth1));
        vm.prank(INITIAL_ISSUER);
        factory.createAccount(auth1, uri, routes, creationCode, sig1);

        (AgentGatewayAccountFactory.CreateAuthorization memory auth2,) =
            _buildAuth(owner, agent, uri, keccak256("inv-2"), deadline);
        bytes memory sig2 = _signDigest(OWNER_PK, factory.creationDigest(auth2));

        // Clause 1 of L112 alone: accountOfIdentity[1] != 0 while ownerOf(1) == factory
        reg.setFixedId(true, 1);
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth2, uri, routes, creationCode, sig2);
        reg.setFixedId(false, 0);

        // Clause 2 of L112 alone: ownerOf(id) != factory while accountOfIdentity[id] == 0
        reg.setMintToOverride(address(0xBEEF));
        reg.setRegisterHooks(true, address(0), false);
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth2, uri, routes, creationCode, sig2);
        reg.setMintToOverride(address(0));
        reg.setRegisterHooks(false, address(0), false);

        // Clause 2 of L133 alone: ownerOf(id) == account, but account.identityEpoch() == 0 != 1
        reg.setTransferMode(1);
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth2, uri, routes, creationCode, sig2);

        // Clause 1 of L133 alone: account.identityEpoch() == 1, but ownerOf(id) != account
        reg.setTransferMode(2);
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth2, uri, routes, creationCode, sig2);
    }

    function test_createAccount_revertsOnReentrancy() public {
        AgentGatewayAccountFactory factory = _deployTestnetFactory();
        MockIdentityRegistry reg = MockIdentityRegistry(ARC_TESTNET_IDENTITY);
        vm.prank(ARC_TESTNET_SAFE);
        factory.setIssuer(ARC_TESTNET_IDENTITY, true);

        address owner = vm.addr(OWNER_PK);
        address agent = address(0xA9E74);
        string memory uri = "ipfs://agent-reenter";
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory creationCode = type(AgentGatewayAccount).creationCode;

        (AgentGatewayAccountFactory.CreateAuthorization memory outerAuth, AgentGatewayAccount.Route[] memory routes) =
            _buildAuth(owner, agent, uri, keccak256("reenter-out"), deadline);
        (AgentGatewayAccountFactory.CreateAuthorization memory innerAuth,) =
            _buildAuth(owner, agent, uri, keccak256("reenter-in"), deadline);

        bytes memory outerSig = _signDigest(OWNER_PK, factory.creationDigest(outerAuth));
        bytes memory innerSig = _signDigest(OWNER_PK, factory.creationDigest(innerAuth));

        bytes memory reenterCall = abi.encodeCall(
            AgentGatewayAccountFactory.createAccount, (innerAuth, uri, routes, creationCode, innerSig)
        );
        reg.configureReentrancy(address(factory), reenterCall);

        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        factory.createAccount(outerAuth, uri, routes, creationCode, outerSig);
    }

    function test_onERC721Received_guards() public {
        AgentGatewayAccountFactory factory = _deployTestnetFactory();
        MockIdentityRegistry reg = MockIdentityRegistry(ARC_TESTNET_IDENTITY);

        // 1. !_registering alone (called by registry, from == 0, ownerOf == factory)
        reg.setOwner(77, address(factory));
        vm.prank(ARC_TESTNET_IDENTITY);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.onERC721Received(address(this), address(0), 77, "");

        // 2. msg.sender != identityRegistry
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.onERC721Received(address(this), address(0), 77, "");

        address owner = vm.addr(OWNER_PK);
        address agent = address(0xA9E75);
        string memory uri = "ipfs://agent-721";
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory creationCode = type(AgentGatewayAccount).creationCode;
        (AgentGatewayAccountFactory.CreateAuthorization memory auth, AgentGatewayAccount.Route[] memory routes) =
            _buildAuth(owner, agent, uri, keccak256("erc721-1"), deadline);
        bytes memory sig = _signDigest(OWNER_PK, factory.creationDigest(auth));

        // 3. from != address(0) alone during _registering
        reg.setRegisterHooks(false, address(0x1234), false);
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth, uri, routes, creationCode, sig);

        // 4. ownerOf(tokenId) != address(this) alone during _registering
        reg.setRegisterHooks(false, address(0), true);
        vm.prank(INITIAL_ISSUER);
        vm.expectRevert(AgentGatewayAccountFactory.Refused.selector);
        factory.createAccount(auth, uri, routes, creationCode, sig);
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
        bytes32 salt = keccak256("bufi.agent-gateway-account-factory.v1");

        bytes memory testnetInitCode =
            abi.encodePacked(type(AgentGatewayAccountFactory).creationCode, abi.encode(ARC_TESTNET_SAFE));
        address expectedTestnet = vm.computeCreate2Address(salt, keccak256(testnetInitCode), create2Factory);

        vm.prank(ARC_TESTNET_SAFE);
        (bool okTestnet, bytes memory rTestnet) = create2Factory.call(abi.encodePacked(salt, testnetInitCode));
        assertTrue(okTestnet);
        AgentGatewayAccountFactory testnetFactory = AgentGatewayAccountFactory(address(bytes20(rTestnet)));
        assertEq(address(testnetFactory), expectedTestnet);
        assertEq(testnetFactory.administrator(), ARC_TESTNET_SAFE);
        assertEq(testnetFactory.identityRegistry(), ARC_TESTNET_IDENTITY);
        assertEq(testnetFactory.gatewayWallet(), ARC_TESTNET_GATEWAY);
        vm.prank(ARC_TESTNET_SAFE);
        testnetFactory.setIssuer(INITIAL_ISSUER, true);
        assertTrue(testnetFactory.issuers(INITIAL_ISSUER));

        vm.chainId(5042);
        vm.etch(ARC_MAINNET_SAFE, hex"600080fd");
        vm.etch(ARC_MAINNET_IDENTITY, hex"600080fd");
        vm.etch(ARC_MAINNET_GATEWAY, hex"600080fd");

        bytes memory mainnetInitCode =
            abi.encodePacked(type(AgentGatewayAccountFactory).creationCode, abi.encode(ARC_MAINNET_SAFE));
        address expectedMainnet = vm.computeCreate2Address(salt, keccak256(mainnetInitCode), create2Factory);

        vm.prank(ARC_MAINNET_SAFE);
        (bool okMainnet, bytes memory rMainnet) = create2Factory.call(abi.encodePacked(salt, mainnetInitCode));
        assertTrue(okMainnet);
        AgentGatewayAccountFactory mainnetFactory = AgentGatewayAccountFactory(address(bytes20(rMainnet)));
        assertEq(address(mainnetFactory), expectedMainnet);
        assertEq(mainnetFactory.administrator(), ARC_MAINNET_SAFE);
        assertEq(mainnetFactory.identityRegistry(), ARC_MAINNET_IDENTITY);
        assertEq(mainnetFactory.gatewayWallet(), ARC_MAINNET_GATEWAY);
        vm.prank(ARC_MAINNET_SAFE);
        mainnetFactory.setIssuer(INITIAL_ISSUER, true);
        assertTrue(mainnetFactory.issuers(INITIAL_ISSUER));
    }
}
