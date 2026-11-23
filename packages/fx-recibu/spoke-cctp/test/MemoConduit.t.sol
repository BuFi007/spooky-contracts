// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MemoConduit, IAddressBook, IMemoCctpXFeeManager} from "../src/rails/MemoConduit.sol";
import {SpokeMemoConduit} from "../src/rails/SpokeMemoConduit.sol";
import {CctpConfig} from "../src/rails/MemoConduitCctpConfig.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function roll(uint256) external;
    function deal(address, uint256) external;
    function chainId(uint256) external;
    function etch(address, bytes calldata) external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool, address) external;
}

contract SpokeMockAddressBook is IAddressBook {
    mapping(address => address[]) internal _allowed;

    function setAllowed(address account, address recipient) external {
        _allowed[account].push(recipient);
    }

    function clearAllowed(address account) external {
        delete _allowed[account];
    }

    function getAllowedRecipients(address account) external view override returns (address[] memory) {
        return _allowed[account];
    }
}

contract SpokeMockToken is ERC20 {
    uint8 public customDecimals;
    uint8 public receiveMode;
    bytes32 public lastNonce;

    address public reenterTarget;
    bytes public reenterCalldata;
    uint256 public reenterValue;

    constructor() ERC20("Mock Token", "MOCK") {}

    receive() external payable {}

    function setDecimals(uint8 d) external {
        customDecimals = d;
    }

    function decimals() public view override returns (uint8) {
        return customDecimals == 0 ? 6 : customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setReceiveMode(uint8 mode) external {
        receiveMode = mode;
    }

    function configureReentrancy(address target, bytes calldata data, uint256 value) external {
        reenterTarget = target;
        reenterCalldata = data;
        reenterValue = value;
        receiveMode = 5;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32 nonce,
        bytes calldata
    ) external {
        lastNonce = nonce;
        uint8 mode = receiveMode;
        if (mode == 1) {
            _transfer(from, to, value - 1);
            return;
        }
        if (mode == 2) {
            _transfer(from, to, value);
            _mint(to, 1);
            return;
        }
        if (mode == 3) {
            _mint(to, value);
            return;
        }
        if (mode == 4) {
            _burn(from, 1);
            _transfer(from, to, value - 1);
            return;
        }
        if (mode == 5) {
            receiveMode = 0;
            _transfer(from, to, value);
            (bool ok, bytes memory ret) = reenterTarget.call{value: reenterValue}(reenterCalldata);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            return;
        }
        _transfer(from, to, value);
    }
}

contract SpokeMockCctpMinter {
    mapping(address => uint256) public burnLimits;

    function setBurnLimit(address token, uint256 limit) external {
        burnLimits[token] = limit;
    }

    function burnLimitsPerMessage(address token) external view returns (uint256) {
        return burnLimits[token];
    }
}

contract SpokeMockCctpMessenger {
    address public localMinterAddr;
    mapping(uint32 => bytes32) public remoteMessengers;
    uint8 public burnMode;
    address public sabotageFrom;

    function setLocalMinter(address m) external {
        localMinterAddr = m;
    }

    function setRemoteTokenMessenger(uint32 domain, bytes32 remote) external {
        remoteMessengers[domain] = remote;
    }

    function setBurnMode(uint8 mode, address from) external {
        burnMode = mode;
        sabotageFrom = from;
    }

    function localMinter() external view returns (address) {
        return localMinterAddr;
    }

    function remoteTokenMessengers(uint32 domain) external view returns (bytes32) {
        return remoteMessengers[domain];
    }

    function depositForBurn(uint256 amount, uint32, bytes32, address burnToken, bytes32, uint256, uint32) external {
        SpokeMockToken tok = SpokeMockToken(payable(burnToken));
        if (burnMode == 1) {
            tok.transferFrom(msg.sender, address(this), amount);
            return;
        }
        if (burnMode == 2) {
            tok.burnFrom(address(this), amount);
            return;
        }
        if (burnMode == 3) {
            tok.transferFrom(msg.sender, address(this), amount);
            tok.burnFrom(address(this), amount);
            tok.mint(sabotageFrom, 1);
            tok.burnFrom(address(this), 1);
            return;
        }
        tok.transferFrom(msg.sender, address(this), amount);
        tok.burnFrom(address(this), amount);
    }
}

contract SpokeMockCctpXFeeManager is IMemoCctpXFeeManager {
    address public qFeeToken;
    uint256 public qExpiry;
    uint256 public qNonce;
    bytes public qSignature;
    QuoteItem[] internal _items;

    function setQuoteMeta(address feeToken_, uint256 expiry_, uint256 nonce_, bytes calldata sig_) external {
        qFeeToken = feeToken_;
        qExpiry = expiry_;
        qNonce = nonce_;
        qSignature = sig_;
    }

    function clearItems() external {
        delete _items;
    }

    function pushItem(string calldata quoteType_, uint256 amount_) external {
        _items.push(QuoteItem({quoteType: quoteType_, quoteArgsHash: bytes32(0), amount: amount_}));
    }

    function decodeQuote(bytes calldata) external view override returns (Quote memory q) {
        q.feeToken = qFeeToken;
        q.expiry = qExpiry;
        q.nonce = qNonce;
        q.signature = qSignature;
        q.items = new QuoteItem[](_items.length);
        for (uint256 i; i < _items.length; ++i) {
            q.items[i] = _items[i];
        }
    }
}

contract SpokeMockCctpXTokenManager {
    uint8 public tmType = 1;
    address public tmToken;
    address public tmService;

    function configure(uint8 t, address tok, address svc) external {
        tmType = t;
        tmToken = tok;
        tmService = svc;
    }

    function tokenManagerType() external view returns (uint8) {
        return tmType;
    }

    function token() external view returns (address) {
        return tmToken;
    }

    function service() external view returns (address) {
        return tmService;
    }

    function pullAndBurn(address from, uint256 amount, uint8 burnMode, address sabotageFrom) external {
        SpokeMockToken tok = SpokeMockToken(payable(tmToken));
        if (burnMode == 1) {
            tok.transferFrom(from, address(this), amount);
            return;
        }
        if (burnMode == 2) {
            tok.burnFrom(address(this), amount);
            return;
        }
        if (burnMode == 3) {
            tok.transferFrom(from, address(this), amount);
            tok.burnFrom(address(this), amount);
            tok.mint(sabotageFrom, 1);
            tok.burnFrom(address(this), 1);
            return;
        }
        tok.transferFrom(from, address(this), amount);
        tok.burnFrom(address(this), amount);
    }
}

contract SpokeMockCctpXService {
    bool public isPaused;
    mapping(uint32 => bool) public trustedDomains;
    mapping(bytes32 => address) public tokenManagers;
    address public feeSvc;
    uint8 public burnMode;
    address public sabotageFrom;

    function setPaused(bool p) external {
        isPaused = p;
    }

    function setTrustedDomain(uint32 domain, bool trusted) external {
        trustedDomains[domain] = trusted;
    }

    function setTokenManager(bytes32 tokenId, address manager) external {
        tokenManagers[tokenId] = manager;
    }

    function setFeeService(address fs) external {
        feeSvc = fs;
    }

    function setBurnMode(uint8 mode, address from) external {
        burnMode = mode;
        sabotageFrom = from;
    }

    function paused() external view returns (bool) {
        return isPaused;
    }

    function isTrustedDomain(uint32 domain) external view returns (bool) {
        return trustedDomains[domain];
    }

    function resolveTokenManager(bytes32 tokenId) external view returns (address) {
        return tokenManagers[tokenId];
    }

    function feeService() external view returns (address) {
        return feeSvc;
    }

    struct QuoteClaim {
        bytes signedQuote;
        address refundAddress;
    }

    function crossChainTransfer(
        bytes32 tokenId,
        uint256 amount,
        uint32,
        bytes calldata,
        bytes32,
        uint32,
        QuoteClaim calldata,
        bool,
        bytes calldata
    ) external payable {
        SpokeMockCctpXTokenManager(tokenManagers[tokenId]).pullAndBurn(msg.sender, amount, burnMode, sabotageFrom);
        if (burnMode == 4) {
            Vm(address(uint160(uint256(keccak256("hevm cheat code"))))).deal(msg.sender, msg.sender.balance + 1);
        }
    }
}

contract SpokeMemoConduitTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant AVAX_USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant FUJI_USDC = 0x5425890298aed601595a70AB815c96711a31Bc65;

    address internal constant SEPOLIA_EURC = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
    address internal constant BASE_SEPOLIA_EURC = 0x808456652fdb597867f38412077A9182bf77359F;
    address internal constant FUJI_EURC = 0x5E44db7996c682E92a960b65AC713a54AD815c6B;
    address internal constant ARC_TESTNET_EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    address internal constant SEPOLIA_CIRBTC = 0x3a3fe695F684Bf9b9e43CF43C2b895Ea5e392bB3;
    address internal constant ARC_TESTNET_CIRBTC = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;

    bytes32 internal constant EURC_TOKEN_ID = 0x2587821a0ee7daa174b95436b5dab1731cfa1844775b010217d3c0dd02a4eecd;
    bytes32 internal constant CIRBTC_TOKEN_ID = 0x7c27b7b6485f3ea49b7d1a439e288d3c3116f533302afabb7e372dfc0770cc7d;

    SpokeMockAddressBook internal book;
    SpokeMockToken internal tokenImpl;
    SpokeMockCctpMessenger internal messenger;
    SpokeMockCctpMinter internal minter;
    SpokeMockCctpXService internal ccts;
    SpokeMockCctpXFeeManager internal feeManager;
    SpokeMockCctpXTokenManager internal eurcManager;
    SpokeMockCctpXTokenManager internal cirbtcManager;
    MemoConduit internal conduit;

    address internal payer = address(0xA11CE001);
    address internal recipient = address(0xB0B00001);
    address internal otherRecipient = address(0xC0C00001);
    address internal transmitter = address(0x7777);

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(500);
        vm.chainId(5042002);

        book = new SpokeMockAddressBook();
        tokenImpl = new SpokeMockToken();
        messenger = new SpokeMockCctpMessenger();
        minter = new SpokeMockCctpMinter();
        ccts = new SpokeMockCctpXService();
        feeManager = new SpokeMockCctpXFeeManager();
        eurcManager = new SpokeMockCctpXTokenManager();
        cirbtcManager = new SpokeMockCctpXTokenManager();

        vm.etch(payer, hex"600080fd");
        book.setAllowed(payer, otherRecipient);
        book.setAllowed(payer, recipient);

        _etchToken(ARC_USDC, 6);
        _etchToken(AVAX_USDC, 6);
        _etchToken(BASE_SEPOLIA_USDC, 6);
        _etchToken(FUJI_USDC, 6);
        _etchToken(SEPOLIA_EURC, 6);
        _etchToken(BASE_SEPOLIA_EURC, 6);
        _etchToken(FUJI_EURC, 6);
        _etchToken(ARC_TESTNET_EURC, 6);
        _etchToken(SEPOLIA_CIRBTC, 8);
        _etchToken(ARC_TESTNET_CIRBTC, 8);

        messenger.setLocalMinter(address(minter));
        messenger.setRemoteTokenMessenger(1, bytes32(uint256(uint160(address(messenger)))));
        messenger.setRemoteTokenMessenger(6, bytes32(uint256(uint160(address(messenger)))));
        messenger.setRemoteTokenMessenger(26, bytes32(uint256(uint160(address(messenger)))));

        minter.setBurnLimit(ARC_USDC, type(uint256).max);
        minter.setBurnLimit(AVAX_USDC, type(uint256).max);
        minter.setBurnLimit(FUJI_USDC, type(uint256).max);

        ccts.setFeeService(address(feeManager));
        ccts.setTrustedDomain(0, true);
        ccts.setTrustedDomain(1, true);
        ccts.setTrustedDomain(6, true);
        ccts.setTrustedDomain(26, true);
        ccts.setTokenManager(EURC_TOKEN_ID, address(eurcManager));
        ccts.setTokenManager(CIRBTC_TOKEN_ID, address(cirbtcManager));

        eurcManager.configure(1, ARC_TESTNET_EURC, address(ccts));
        cirbtcManager.configure(1, SEPOLIA_CIRBTC, address(ccts));

        conduit = new MemoConduit(book, _allSupportedTokens(), _defaultConfig());

        SpokeMockToken(payable(ARC_USDC)).mint(payer, 1_000e6);
        SpokeMockToken(payable(FUJI_USDC)).mint(payer, 1_000e6);
        SpokeMockToken(payable(ARC_TESTNET_EURC)).mint(payer, 1_000e6);
        SpokeMockToken(payable(SEPOLIA_CIRBTC)).mint(payer, 1_000e8);
    }

    function _etchToken(address addr, uint8 dec) internal {
        vm.etch(addr, address(tokenImpl).code);
        SpokeMockToken(payable(addr)).setDecimals(dec);
    }

    function _allSupportedTokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](10);
        tokens[0] = ARC_USDC;
        tokens[1] = AVAX_USDC;
        tokens[2] = BASE_SEPOLIA_USDC;
        tokens[3] = FUJI_USDC;
        tokens[4] = SEPOLIA_EURC;
        tokens[5] = BASE_SEPOLIA_EURC;
        tokens[6] = FUJI_EURC;
        tokens[7] = ARC_TESTNET_EURC;
        tokens[8] = SEPOLIA_CIRBTC;
        tokens[9] = ARC_TESTNET_CIRBTC;
    }

    function _defaultConfig() internal view returns (CctpConfig memory) {
        return CctpConfig({
            tokenMessenger: address(messenger),
            messageTransmitter: transmitter,
            tokenMinter: address(minter),
            ccts: address(ccts),
            eurcManager: address(eurcManager),
            cirbtcManager: address(cirbtcManager)
        });
    }

    function _usdcBridgePayment(bytes32 memoId) internal view returns (MemoConduit.BridgePayment memory) {
        return MemoConduit.BridgePayment({
            protocol: 1,
            token: ARC_USDC,
            from: payer,
            recipient: recipient,
            amount: 100e6,
            destinationChainId: 43114,
            destinationDomain: 1,
            destinationToken: AVAX_USDC,
            maxFee: 0,
            minFinalityThreshold: 2000,
            validAfter: 0,
            validBefore: block.timestamp + 1 hours,
            paymentId: keccak256("pay-usdc"),
            termsHash: keccak256("terms-usdc"),
            memoId: memoId,
            memo: "usdc-bridge",
            tokenId: bytes32(0),
            quoteHash: bytes32(0),
            nativeFee: 0,
            quoteValidUntil: 0
        });
    }

    function _eurcBridgePayment(bytes32 memoId, bytes memory signedQuote, uint256 nativeFee, uint256 quoteValidUntil)
        internal
        view
        returns (MemoConduit.BridgePayment memory)
    {
        return MemoConduit.BridgePayment({
            protocol: 2,
            token: ARC_TESTNET_EURC,
            from: payer,
            recipient: recipient,
            amount: 100e6,
            destinationChainId: 11155111,
            destinationDomain: 0,
            destinationToken: SEPOLIA_EURC,
            maxFee: 0,
            minFinalityThreshold: 2000,
            validAfter: 0,
            validBefore: quoteValidUntil - 10,
            paymentId: keccak256("pay-eurc"),
            termsHash: keccak256("terms-eurc"),
            memoId: memoId,
            memo: "eurc-bridge",
            tokenId: EURC_TOKEN_ID,
            quoteHash: keccak256(signedQuote),
            nativeFee: nativeFee,
            quoteValidUntil: quoteValidUntil
        });
    }

    function _setupStandardQuote(uint256 expiry, uint256 forwardAmt, uint256 protocolAmt, bool reverseOrder) internal {
        feeManager.setQuoteMeta(address(0), expiry, 1, hex"aabbcc");
        feeManager.clearItems();
        if (reverseOrder) {
            feeManager.pushItem("PROTOCOL", protocolAmt);
            feeManager.pushItem("FORWARD", forwardAmt);
        } else {
            feeManager.pushItem("FORWARD", forwardAmt);
            feeManager.pushItem("PROTOCOL", protocolAmt);
        }
    }

    function test_constants_and_constructor_guards() public {
        require(conduit.CCTP_V2_USDC() == 1, "usdc id");
        require(conduit.CCTPX_EURC() == 2, "eurc id");
        require(conduit.CCTPX_CIRBTC() == 3, "cirbtc id");
        require(conduit.CCTP_STANDARD_FINALITY() == 2000, "finality");
        require(conduit.CCTPX_EURC_TOKEN_ID() == EURC_TOKEN_ID, "eurc tokenId");
        require(conduit.CCTPX_CIRBTC_TOKEN_ID() == CIRBTC_TOKEN_ID, "cirbtc tokenId");

        address[] memory tokens = new address[](1);
        tokens[0] = ARC_USDC;
        CctpConfig memory emptyCfg;

        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        new MemoConduit(IAddressBook(address(0)), tokens, emptyCfg);

        address[] memory badTokens = new address[](1);
        badTokens[0] = address(0);
        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        new MemoConduit(book, badTokens, emptyCfg);

        CctpConfig memory onlyMessenger;
        onlyMessenger.tokenMessenger = address(messenger);
        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        new MemoConduit(book, tokens, onlyMessenger);

        CctpConfig memory onlyMinter;
        onlyMinter.tokenMinter = address(minter);
        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        new MemoConduit(book, tokens, onlyMinter);

        MemoConduit disabledCctp = new MemoConduit(book, tokens, emptyCfg);
        require(disabledCctp.CCTP_TOKEN_MESSENGER() == address(0), "disabled messenger");
        require(disabledCctp.CCTP_TOKEN_MINTER() == address(0), "disabled minter");
    }

    function test_payWithMemo_happyPath_guards_and_reentrancy() public {
        SpokeMockToken usdc = SpokeMockToken(payable(ARC_USDC));
        usdc.mint(address(conduit), 77);
        bytes32 memoId = keccak256("pay-happy");

        vm.expectEmit(true, true, true, true, address(conduit));
        emit MemoConduit.MemoConduitPayment(memoId, payer, recipient, ARC_USDC, 50e6, "memo-ok");
        conduit.payWithMemo(ARC_USDC, payer, recipient, 50e6, 0, 1000, memoId, "memo-ok", hex"01");

        require(usdc.balanceOf(address(conduit)) == 77, "donation preserved");
        require(usdc.balanceOf(recipient) == 50e6, "recipient received");
        require(conduit.memoPaymentCommitment(payer, memoId) != bytes32(0), "commitment recorded");

        vm.expectRevert(MemoConduit.ZeroAmount.selector);
        conduit.payWithMemo(ARC_USDC, payer, recipient, 0, 0, 1000, keccak256("p-zero"), "m", hex"01");

        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        conduit.payWithMemo(ARC_USDC, payer, address(0), 10e6, 0, 1000, keccak256("p-zr"), "m", hex"01");

        address badTok = address(0x9999);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.TokenNotSupported.selector, badTok));
        conduit.payWithMemo(badTok, payer, recipient, 10e6, 0, 1000, keccak256("p-tok"), "m", hex"01");

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.MemoAlreadyPaid.selector, payer, memoId));
        conduit.payWithMemo(ARC_USDC, payer, recipient, 10e6, 0, 1000, memoId, "m", hex"01");

        address notAllowed = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.RecipientNotAllowlisted.selector, payer, notAllowed));
        conduit.payWithMemo(ARC_USDC, payer, notAllowed, 10e6, 0, 1000, keccak256("p-na"), "m", hex"01");

        usdc.setReceiveMode(1);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BalanceChanged.selector, uint256(77), uint256(76)));
        conduit.payWithMemo(ARC_USDC, payer, recipient, 10e6, 0, 1000, keccak256("p-short"), "m", hex"01");

        usdc.setReceiveMode(2);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BalanceChanged.selector, uint256(77), uint256(78)));
        conduit.payWithMemo(ARC_USDC, payer, recipient, 10e6, 0, 1000, keccak256("p-excess"), "m", hex"01");

        bytes memory reenterPay = abi.encodeCall(
            MemoConduit.payWithMemo,
            (ARC_USDC, payer, recipient, 5e6, 0, 1000, keccak256("p-reenter-in"), bytes("reenter"), hex"01")
        );
        usdc.configureReentrancy(address(conduit), reenterPay, 0);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        conduit.payWithMemo(ARC_USDC, payer, recipient, 10e6, 0, 1000, keccak256("p-reenter-out"), "m", hex"01");
    }

    function test_crossRail_replay_prevention() public {
        vm.chainId(5042);
        bytes32 memoBridgedFirst = keccak256("cross-1");
        MemoConduit.BridgePayment memory bp1 = _usdcBridgePayment(memoBridgedFirst);
        conduit.bridgeWithMemo(bp1, hex"01");

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeAlreadyDispatched.selector, payer, memoBridgedFirst));
        conduit.payWithMemo(ARC_USDC, payer, recipient, 10e6, 0, 1000, memoBridgedFirst, "m", hex"01");

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeAlreadyDispatched.selector, payer, memoBridgedFirst));
        conduit.bridgeWithMemo(bp1, hex"01");

        bytes32 memoPaidFirst = keccak256("cross-2");
        conduit.payWithMemo(ARC_USDC, payer, recipient, 10e6, 0, 1000, memoPaidFirst, "m", hex"01");

        MemoConduit.BridgePayment memory bp2 = _usdcBridgePayment(memoPaidFirst);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeAlreadyDispatched.selector, payer, memoPaidFirst));
        conduit.bridgeWithMemo(bp2, hex"01");
    }

    function test_bridgeTokenIdOf_and_bridgeTokenManagerOf() public {
        require(conduit.bridgeTokenIdOf(1) == bytes32(0), "usdc tokenId");
        require(conduit.bridgeTokenIdOf(2) == EURC_TOKEN_ID, "eurc tokenId");
        require(conduit.bridgeTokenIdOf(3) == CIRBTC_TOKEN_ID, "cirbtc tokenId");

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(0)));
        conduit.bridgeTokenIdOf(0);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(4)));
        conduit.bridgeTokenIdOf(4);

        require(conduit.bridgeTokenManagerOf(1) == address(minter), "usdc manager");
        require(conduit.bridgeTokenManagerOf(2) == address(eurcManager), "eurc manager");
        require(conduit.bridgeTokenManagerOf(3) == address(cirbtcManager), "cirbtc manager");

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(0)));
        conduit.bridgeTokenManagerOf(0);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(4)));
        conduit.bridgeTokenManagerOf(4);
    }

    function test_bridgeRouteOf_mainnet_testnet_unknownChain_and_errors() public {
        // Mainnet bidirectional Arc 5042 <-> Avalanche 43114
        vm.chainId(5042);
        (uint32 sDom, uint32 dDom, address dTok, address msgAddr) = conduit.bridgeRouteOf(1, ARC_USDC, 43114);
        require(sDom == 26 && dDom == 1 && dTok == AVAX_USDC && msgAddr == address(messenger), "arc->avax");

        // Mainnet same chain
        vm.expectRevert(
            abi.encodeWithSelector(MemoConduit.BridgeRouteNotSupported.selector, uint256(5042), uint256(5042), ARC_USDC)
        );
        conduit.bridgeRouteOf(1, ARC_USDC, 5042);

        // Mainnet wrong token
        vm.expectRevert(
            abi.encodeWithSelector(
                MemoConduit.BridgeRouteNotSupported.selector, uint256(5042), uint256(43114), AVAX_USDC
            )
        );
        conduit.bridgeRouteOf(1, AVAX_USDC, 43114);

        // Mainnet unsupported destination chain
        vm.expectRevert(
            abi.encodeWithSelector(MemoConduit.BridgeRouteNotSupported.selector, uint256(5042), uint256(1), ARC_USDC)
        );
        conduit.bridgeRouteOf(1, ARC_USDC, 1);

        // Mainnet CCTPx EURC & cirBTC are unrouted (BridgeRouteNotSupported, not BridgeProtocolNotSupported)
        vm.expectRevert(
            abi.encodeWithSelector(
                MemoConduit.BridgeRouteNotSupported.selector, uint256(5042), uint256(43114), ARC_USDC
            )
        );
        conduit.bridgeRouteOf(2, ARC_USDC, 43114);

        vm.expectRevert(
            abi.encodeWithSelector(
                MemoConduit.BridgeRouteNotSupported.selector, uint256(5042), uint256(43114), ARC_USDC
            )
        );
        conduit.bridgeRouteOf(3, ARC_USDC, 43114);

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(9)));
        conduit.bridgeRouteOf(9, ARC_USDC, 43114);

        // Unsupported token in conduit mapping
        address[] memory onlyAvax = new address[](1);
        onlyAvax[0] = AVAX_USDC;
        MemoConduit limited = new MemoConduit(book, onlyAvax, _defaultConfig());
        vm.expectRevert(
            abi.encodeWithSelector(
                MemoConduit.BridgeRouteNotSupported.selector, uint256(5042), uint256(43114), ARC_USDC
            )
        );
        limited.bridgeRouteOf(1, ARC_USDC, 43114);

        // Avalanche mainnet -> Arc mainnet
        vm.chainId(43114);
        (sDom, dDom, dTok, msgAddr) = conduit.bridgeRouteOf(1, AVAX_USDC, 5042);
        require(sDom == 1 && dDom == 26 && dTok == ARC_USDC && msgAddr == address(messenger), "avax->arc");

        // Mainnet -> Testnet fails closed
        vm.expectRevert(
            abi.encodeWithSelector(
                MemoConduit.BridgeRouteNotSupported.selector, uint256(43114), uint256(5042002), AVAX_USDC
            )
        );
        conduit.bridgeRouteOf(1, AVAX_USDC, 5042002);

        // Testnet USDC routes (including Base Sepolia 84532)
        vm.chainId(84532);
        (sDom, dDom, dTok, msgAddr) = conduit.bridgeRouteOf(1, BASE_SEPOLIA_USDC, 5042002);
        require(sDom == 6 && dDom == 26 && dTok == ARC_USDC && msgAddr == address(messenger), "baseSep->arcTest");

        vm.chainId(5042002);
        (sDom, dDom, dTok, msgAddr) = conduit.bridgeRouteOf(1, ARC_USDC, 84532);
        require(sDom == 26 && dDom == 6 && dTok == BASE_SEPOLIA_USDC && msgAddr == address(messenger), "arcTest->baseSep");

        // Testnet EURC routes across all 4 chains
        vm.chainId(11155111);
        (sDom, dDom, dTok, msgAddr) = conduit.bridgeRouteOf(2, SEPOLIA_EURC, 5042002);
        require(sDom == 0 && dDom == 26 && dTok == ARC_TESTNET_EURC && msgAddr == address(ccts), "sep->arc eurc");

        // Sepolia USDC is unrouted
        vm.expectRevert(
            abi.encodeWithSelector(
                MemoConduit.BridgeRouteNotSupported.selector, uint256(11155111), uint256(5042002), ARC_USDC
            )
        );
        conduit.bridgeRouteOf(1, ARC_USDC, 5042002);

        vm.chainId(84532);
        (sDom, dDom, dTok, msgAddr) = conduit.bridgeRouteOf(2, BASE_SEPOLIA_EURC, 43113);
        require(sDom == 6 && dDom == 1 && dTok == FUJI_EURC && msgAddr == address(ccts), "baseSep->fuji eurc");

        vm.chainId(43113);
        (sDom, dDom, dTok, msgAddr) = conduit.bridgeRouteOf(2, FUJI_EURC, 84532);
        require(sDom == 1 && dDom == 6 && dTok == BASE_SEPOLIA_EURC && msgAddr == address(ccts), "fuji->baseSep eurc");

        vm.chainId(5042002);
        (sDom, dDom, dTok, msgAddr) = conduit.bridgeRouteOf(2, ARC_TESTNET_EURC, 11155111);
        require(sDom == 26 && dDom == 0 && dTok == SEPOLIA_EURC && msgAddr == address(ccts), "arc->sep eurc");

        vm.expectRevert(
            abi.encodeWithSelector(
                MemoConduit.BridgeRouteNotSupported.selector, uint256(5042002), uint256(999), ARC_TESTNET_EURC
            )
        );
        conduit.bridgeRouteOf(2, ARC_TESTNET_EURC, 999);

        // Testnet cirBTC routes
        vm.chainId(11155111);
        (sDom, dDom, dTok, msgAddr) = conduit.bridgeRouteOf(3, SEPOLIA_CIRBTC, 5042002);
        require(sDom == 0 && dDom == 26 && dTok == ARC_TESTNET_CIRBTC && msgAddr == address(ccts), "sep->arc cirbtc");

        vm.chainId(5042002);
        (sDom, dDom, dTok, msgAddr) = conduit.bridgeRouteOf(3, ARC_TESTNET_CIRBTC, 11155111);
        require(sDom == 26 && dDom == 0 && dTok == SEPOLIA_CIRBTC && msgAddr == address(ccts), "arc->sep cirbtc");

        vm.expectRevert(
            abi.encodeWithSelector(
                MemoConduit.BridgeRouteNotSupported.selector, uint256(5042002), uint256(43113), ARC_TESTNET_CIRBTC
            )
        );
        conduit.bridgeRouteOf(3, ARC_TESTNET_CIRBTC, 43113);

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(4)));
        conduit.bridgeRouteOf(4, ARC_USDC, 43113);

        // Unknown chainId
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(0)));
        conduit.bridgeRouteOf(0, ARC_USDC, 5042);

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(4)));
        conduit.bridgeRouteOf(4, ARC_USDC, 5042);

        vm.expectRevert(
            abi.encodeWithSelector(MemoConduit.BridgeRouteNotSupported.selector, uint256(1), uint256(5042), ARC_USDC)
        );
        conduit.bridgeRouteOf(1, ARC_USDC, 5042);

        vm.expectRevert(
            abi.encodeWithSelector(MemoConduit.BridgeRouteNotSupported.selector, uint256(1), uint256(5042), ARC_USDC)
        );
        conduit.bridgeRouteOf(2, ARC_USDC, 5042);

        vm.expectRevert(
            abi.encodeWithSelector(MemoConduit.BridgeRouteNotSupported.selector, uint256(1), uint256(5042), ARC_USDC)
        );
        conduit.bridgeRouteOf(3, ARC_USDC, 5042);
    }

    function _expectedBridgeNonce(MemoConduit.BridgePayment memory bp, address expectedMessenger)
        internal
        view
        returns (bytes32)
    {
        bytes memory part1 = abi.encode(
            conduit.BRIDGE_PAYMENT_NONCE_TYPEHASH(),
            block.chainid,
            address(conduit),
            bp.protocol,
            expectedMessenger,
            bp.token,
            bp.from,
            bp.recipient,
            bp.amount,
            bp.destinationChainId,
            bp.destinationDomain,
            bp.destinationToken
        );
        bytes memory part2 = abi.encode(
            bp.maxFee,
            bp.minFinalityThreshold,
            bp.validAfter,
            bp.validBefore,
            bp.paymentId,
            bp.termsHash,
            bp.memoId,
            keccak256(bp.memo),
            bp.tokenId,
            bp.quoteHash,
            bp.nativeFee,
            bp.quoteValidUntil
        );
        return keccak256(bytes.concat(part1, part2));
    }

    function test_bridgePaymentNonceOf_selectsCorrectMessenger() public {
        vm.chainId(5042);
        MemoConduit.BridgePayment memory bpUsdc = _usdcBridgePayment(keccak256("n-usdc"));
        require(
            conduit.bridgePaymentNonceOf(bpUsdc) == _expectedBridgeNonce(bpUsdc, address(messenger)),
            "usdc nonce messenger"
        );

        bytes memory sq = hex"01aabb";
        MemoConduit.BridgePayment memory bpEurc =
            _eurcBridgePayment(keccak256("n-eurc"), sq, 0.01 ether, block.timestamp + 100);
        require(
            conduit.bridgePaymentNonceOf(bpEurc) == _expectedBridgeNonce(bpEurc, address(ccts)),
            "eurc nonce messenger"
        );
    }

    function _expectSourceBurn(address target, MemoConduit.BridgePayment memory bp, bytes32 nonce) internal {
        vm.expectEmit(true, true, true, true, target);
        emit MemoConduit.MemoConduitSourceBurn(
            bp.memoId,
            bp.from,
            bp.recipient,
            bp.paymentId,
            bp.termsHash,
            nonce,
            bp.token,
            bp.amount,
            bp.destinationChainId,
            bp.destinationDomain,
            bp.destinationToken,
            bp.memo
        );
    }

    function test_bridgeWithMemo_happyPath() public {
        vm.chainId(5042);
        SpokeMockToken usdc = SpokeMockToken(payable(ARC_USDC));
        usdc.mint(address(conduit), 55);
        minter.setBurnLimit(ARC_USDC, 100e6);

        MemoConduit.BridgePayment memory bp = _usdcBridgePayment(keccak256("b-happy"));
        bytes32 expectedNonce = conduit.bridgePaymentNonceOf(bp);
        uint256 supplyBefore = usdc.totalSupply();

        _expectSourceBurn(address(conduit), bp, expectedNonce);
        conduit.bridgeWithMemo(bp, hex"01");

        require(conduit.bridgePaymentCommitment(payer, bp.memoId) == expectedNonce, "commitment");
        require(usdc.balanceOf(address(conduit)) == 55, "conduit balance unchanged");
        require(usdc.totalSupply() == supplyBefore - 100e6, "burned exact amount");
        require(usdc.allowance(address(conduit), address(messenger)) == 0, "allowance cleared");
    }

    function test_bridgeWithMemo_reentrancy() public {
        vm.chainId(5042);
        SpokeMockToken usdc = SpokeMockToken(payable(ARC_USDC));
        MemoConduit.BridgePayment memory outerBp = _usdcBridgePayment(keccak256("b-reenter-out"));
        MemoConduit.BridgePayment memory innerBp = _usdcBridgePayment(keccak256("b-reenter-in"));
        usdc.configureReentrancy(
            address(conduit), abi.encodeCall(MemoConduit.bridgeWithMemo, (innerBp, hex"01")), 0
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        conduit.bridgeWithMemo(outerBp, hex"01");
    }

    function test_bridgeWithMemo_routeAndQuoteGuards() public {
        vm.chainId(5042);
        MemoConduit.BridgePayment memory bp = _usdcBridgePayment(keccak256("b-guard"));

        bp.protocol = 2;
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(2)));
        conduit.bridgeWithMemo(bp, hex"01");
        bp.protocol = 1;

        bp.destinationDomain = 2;
        vm.expectRevert(MemoConduit.BridgeDestinationMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.destinationDomain = 1;

        bp.destinationToken = ARC_USDC;
        vm.expectRevert(MemoConduit.BridgeDestinationMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.destinationToken = AVAX_USDC;

        bp.maxFee = 1;
        vm.expectRevert(MemoConduit.BridgeFeeOrFinalityNotSupported.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.maxFee = 0;

        bp.minFinalityThreshold = 1000;
        vm.expectRevert(MemoConduit.BridgeFeeOrFinalityNotSupported.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.minFinalityThreshold = 2000;

        bp.tokenId = bytes32(uint256(1));
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.tokenId = bytes32(0);

        bp.quoteHash = bytes32(uint256(1));
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.quoteHash = bytes32(0);

        bp.nativeFee = 1;
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.nativeFee = 0;

        bp.quoteValidUntil = 1;
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
    }

    function test_bridgeWithMemo_payerAndDependencyGuards() public {
        vm.chainId(5042);
        MemoConduit.BridgePayment memory bp = _usdcBridgePayment(keccak256("b-guard-2"));

        bp.amount = 0;
        vm.expectRevert(MemoConduit.ZeroAmount.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.amount = 100e6;

        bp.recipient = address(0);
        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.recipient = recipient;

        bp.from = address(0);
        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        conduit.bridgeWithMemo(bp, hex"01");

        bp.from = address(0xE0AE0A);
        vm.expectRevert(MemoConduit.BridgeRequiresSmartAccount.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.from = payer;

        SpokeMockToken(payable(ARC_USDC)).setDecimals(8);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        SpokeMockToken(payable(ARC_USDC)).setDecimals(6);

        bp.paymentId = bytes32(0);
        vm.expectRevert(MemoConduit.BridgeReferenceMissing.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.paymentId = keccak256("pay-usdc");

        bp.termsHash = bytes32(0);
        vm.expectRevert(MemoConduit.BridgeReferenceMissing.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.termsHash = keccak256("terms-usdc");

        bp.memoId = bytes32(0);
        vm.expectRevert(MemoConduit.BridgeReferenceMissing.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        bp.memoId = keccak256("b-guard-2");

        bp.recipient = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.RecipientNotAllowlisted.selector, payer, address(0xDEAD)));
        conduit.bridgeWithMemo(bp, hex"01");
        bp.recipient = recipient;

        messenger.setLocalMinter(address(0x1111));
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        messenger.setLocalMinter(address(minter));

        messenger.setRemoteTokenMessenger(1, bytes32(uint256(123)));
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        messenger.setRemoteTokenMessenger(1, bytes32(uint256(uint160(address(messenger)))));

        minter.setBurnLimit(ARC_USDC, 100e6 - 1);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        minter.setBurnLimit(ARC_USDC, type(uint256).max);

        CctpConfig memory noCodeCfg = _defaultConfig();
        noCodeCfg.tokenMessenger = address(0x123456);
        MemoConduit noMessengerCode = new MemoConduit(book, _allSupportedTokens(), noCodeCfg);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        noMessengerCode.bridgeWithMemo(bp, hex"01");

        CctpConfig memory noMinterCodeCfg = _defaultConfig();
        noMinterCodeCfg.tokenMinter = address(0x654321);
        MemoConduit noMinterCode = new MemoConduit(book, _allSupportedTokens(), noMinterCodeCfg);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        noMinterCode.bridgeWithMemo(bp, hex"01");
    }

    function test_bridgeWithMemo_debitAndBurnMismatches() public {
        vm.chainId(5042);
        SpokeMockToken usdc = SpokeMockToken(payable(ARC_USDC));
        MemoConduit.BridgePayment memory bp = _usdcBridgePayment(keccak256("b-mismatch"));

        usdc.setReceiveMode(3);
        vm.expectRevert(MemoConduit.BridgeDebitMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");

        usdc.setReceiveMode(4);
        vm.expectRevert(MemoConduit.BridgeDebitMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
        usdc.setReceiveMode(0);

        messenger.setBurnMode(1, payer);
        vm.expectRevert(MemoConduit.BridgeBurnMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");

        usdc.mint(address(messenger), 100e6);
        messenger.setBurnMode(2, payer);
        vm.expectRevert(MemoConduit.BridgeBurnMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");

        messenger.setBurnMode(3, payer);
        vm.expectRevert(MemoConduit.BridgeBurnMismatch.selector);
        conduit.bridgeWithMemo(bp, hex"01");
    }

    function test_bridgeWithMemoCctpX_happyPath_eurc() public {
        vm.chainId(5042002);
        vm.deal(address(this), 10 ether);
        vm.deal(address(conduit), 0.5 ether);

        bytes memory signedQuote = hex"01deadbeef";
        uint256 nativeFee = 0.01 ether;
        uint256 quoteValidUntil = block.timestamp + 600;
        _setupStandardQuote(quoteValidUntil, 0.006 ether, 0.004 ether, false);

        MemoConduit.BridgePayment memory bpEurc =
            _eurcBridgePayment(keccak256("cctpx-eurc-ok"), signedQuote, nativeFee, quoteValidUntil);
        bytes32 expectedNonce = conduit.bridgePaymentNonceOf(bpEurc);
        SpokeMockToken eurc = SpokeMockToken(payable(ARC_TESTNET_EURC));
        uint256 supplyBefore = eurc.totalSupply();

        _expectSourceBurn(address(conduit), bpEurc, expectedNonce);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bpEurc, signedQuote, hex"01");

        require(conduit.bridgePaymentCommitment(payer, bpEurc.memoId) == expectedNonce, "eurc commitment");
        require(eurc.totalSupply() == supplyBefore - 100e6, "eurc burned");
        require(address(conduit).balance == 0.5 ether, "native balance preserved");
        require(eurc.allowance(address(conduit), address(eurcManager)) == 0, "eurc allowance cleared");
    }

    function test_bridgeWithMemoCctpX_reentrancy() public {
        vm.chainId(5042002);
        vm.deal(address(this), 10 ether);
        vm.deal(ARC_TESTNET_EURC, 1 ether);

        bytes memory signedQuote = hex"01deadbeef";
        uint256 nativeFee = 0.01 ether;
        uint256 quoteValidUntil = block.timestamp + 600;
        _setupStandardQuote(quoteValidUntil, 0.006 ether, 0.004 ether, false);

        MemoConduit.BridgePayment memory outerEurc =
            _eurcBridgePayment(keccak256("cctpx-reenter-out"), signedQuote, nativeFee, quoteValidUntil);
        MemoConduit.BridgePayment memory innerEurc =
            _eurcBridgePayment(keccak256("cctpx-reenter-in"), signedQuote, nativeFee, quoteValidUntil);
        SpokeMockToken(payable(ARC_TESTNET_EURC)).configureReentrancy(
            address(conduit),
            abi.encodeCall(MemoConduit.bridgeWithMemoCctpX, (innerEurc, signedQuote, hex"01")),
            nativeFee
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(outerEurc, signedQuote, hex"01");
    }

    function test_bridgeWithMemoCctpX_happyPath_cirbtc() public {
        vm.chainId(11155111);
        vm.deal(address(this), 10 ether);

        bytes memory signedQuote = hex"01deadbeef";
        uint256 nativeFee = 0.01 ether;
        uint256 quoteValidUntil = block.timestamp + 600;
        _setupStandardQuote((uint256(1) << 248) | (block.number + 10), 0.007 ether, 0.003 ether, true);

        MemoConduit.BridgePayment memory bpBtc = MemoConduit.BridgePayment({
            protocol: 3,
            token: SEPOLIA_CIRBTC,
            from: payer,
            recipient: recipient,
            amount: 50e8,
            destinationChainId: 5042002,
            destinationDomain: 26,
            destinationToken: ARC_TESTNET_CIRBTC,
            maxFee: 0,
            minFinalityThreshold: 2000,
            validAfter: 0,
            validBefore: quoteValidUntil - 10,
            paymentId: keccak256("pay-btc"),
            termsHash: keccak256("terms-btc"),
            memoId: keccak256("cctpx-btc-ok"),
            memo: "btc-bridge",
            tokenId: CIRBTC_TOKEN_ID,
            quoteHash: keccak256(signedQuote),
            nativeFee: nativeFee,
            quoteValidUntil: quoteValidUntil
        });

        SpokeMockToken(payable(SEPOLIA_CIRBTC)).setDecimals(6);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bpBtc, signedQuote, hex"01");
        SpokeMockToken(payable(SEPOLIA_CIRBTC)).setDecimals(8);

        bytes32 btcNonce = conduit.bridgePaymentNonceOf(bpBtc);
        _expectSourceBurn(address(conduit), bpBtc, btcNonce);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bpBtc, signedQuote, hex"01");
        require(conduit.bridgePaymentCommitment(payer, bpBtc.memoId) == btcNonce, "btc commitment");
    }

    function test_bridgeWithMemoCctpX_outerGuards() public {
        vm.chainId(5042002);
        vm.deal(address(this), 10 ether);
        bytes memory signedQuote = hex"01cafebabe";
        uint256 nativeFee = 0.01 ether;
        uint256 quoteValidUntil = block.timestamp + 600;
        _setupStandardQuote(quoteValidUntil, 0.006 ether, 0.004 ether, false);

        MemoConduit.BridgePayment memory bp =
            _eurcBridgePayment(keccak256("cctpx-outer"), signedQuote, nativeFee, quoteValidUntil);

        bp.protocol = 1;
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(1)));
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        bp.protocol = 2;

        bp.destinationDomain = 6;
        vm.expectRevert(MemoConduit.BridgeDestinationMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        bp.destinationDomain = 0;

        bp.destinationToken = FUJI_EURC;
        vm.expectRevert(MemoConduit.BridgeDestinationMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        bp.destinationToken = SEPOLIA_EURC;

        bp.maxFee = 1;
        vm.expectRevert(MemoConduit.BridgeFeeOrFinalityNotSupported.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        bp.maxFee = 0;

        bp.minFinalityThreshold = 1000;
        vm.expectRevert(MemoConduit.BridgeFeeOrFinalityNotSupported.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        bp.minFinalityThreshold = 2000;

        bp.tokenId = CIRBTC_TOKEN_ID;
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        bp.tokenId = EURC_TOKEN_ID;

        bytes memory shortQuote = hex"01";
        bp.quoteHash = keccak256(shortQuote);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, shortQuote, hex"01");

        bytes memory v0Quote = hex"00deadbeef";
        bp.quoteHash = keccak256(v0Quote);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, v0Quote, hex"01");

        bp.quoteHash = keccak256("wrong");
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        bp.quoteHash = keccak256(signedQuote);

        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee - 1}(bp, signedQuote, hex"01");

        bp.quoteValidUntil = 0;
        bp.validBefore = 0;
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        bp.quoteValidUntil = quoteValidUntil;

        bp.validBefore = quoteValidUntil + 1;
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        bp.validBefore = quoteValidUntil - 10;

        bp.quoteValidUntil = block.timestamp;
        bp.validBefore = block.timestamp;
        vm.expectRevert(MemoConduit.BridgeQuoteExpired.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
    }

    function test_bridgeWithMemoCctpX_dependencyGuards() public {
        vm.chainId(5042002);
        vm.deal(address(this), 10 ether);
        bytes memory signedQuote = hex"01cafebabe";
        uint256 nativeFee = 0.01 ether;
        uint256 quoteValidUntil = block.timestamp + 600;
        _setupStandardQuote(quoteValidUntil, 0.006 ether, 0.004 ether, false);

        MemoConduit.BridgePayment memory bp =
            _eurcBridgePayment(keccak256("cctpx-deps"), signedQuote, nativeFee, quoteValidUntil);

        ccts.setPaused(true);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        ccts.setPaused(false);

        ccts.setTrustedDomain(0, false);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        ccts.setTrustedDomain(0, true);

        ccts.setTokenManager(EURC_TOKEN_ID, address(cirbtcManager));
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        ccts.setTokenManager(EURC_TOKEN_ID, address(eurcManager));

        eurcManager.configure(2, ARC_TESTNET_EURC, address(ccts));
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        eurcManager.configure(1, SEPOLIA_EURC, address(ccts));
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        eurcManager.configure(1, ARC_TESTNET_EURC, address(0x1111));
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        eurcManager.configure(1, ARC_TESTNET_EURC, address(ccts));

        CctpConfig memory noSvcCfg = _defaultConfig();
        noSvcCfg.ccts = address(0x222222);
        MemoConduit noSvc = new MemoConduit(book, _allSupportedTokens(), noSvcCfg);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        noSvc.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        CctpConfig memory noMgrCfg = _defaultConfig();
        noMgrCfg.eurcManager = address(0x333333);
        MemoConduit noMgr = new MemoConduit(book, _allSupportedTokens(), noMgrCfg);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        noMgr.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        ccts.setFeeService(address(0x444444));
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
    }

    function test_bridgeWithMemoCctpX_nativeQuoteGuards() public {
        vm.chainId(5042002);
        vm.deal(address(this), 10 ether);
        bytes memory signedQuote = hex"01cafebabe";
        uint256 nativeFee = 0.01 ether;
        uint256 quoteValidUntil = block.timestamp + 600;

        MemoConduit.BridgePayment memory bp =
            _eurcBridgePayment(keccak256("cctpx-quote"), signedQuote, nativeFee, quoteValidUntil);

        feeManager.setQuoteMeta(address(0x1), quoteValidUntil, 1, hex"aabb");
        feeManager.clearItems();
        feeManager.pushItem("FORWARD", 0.006 ether);
        feeManager.pushItem("PROTOCOL", 0.004 ether);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        feeManager.setQuoteMeta(address(0), quoteValidUntil, 1, hex"");
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        feeManager.setQuoteMeta(address(0), quoteValidUntil, 1, hex"aabb");
        feeManager.clearItems();
        feeManager.pushItem("FORWARD", nativeFee);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        feeManager.pushItem("PROTOCOL", 0);
        feeManager.pushItem("PRE_FINALITY", 0);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        feeManager.clearItems();
        feeManager.pushItem("FORWARD", 0.006 ether);
        feeManager.pushItem("PRE_FINALITY", 0.004 ether);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        feeManager.clearItems();
        feeManager.pushItem("FORWARD", 0.006 ether);
        feeManager.pushItem("FORWARD", 0.004 ether);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        _setupStandardQuote(quoteValidUntil, 0.006 ether, 0.003 ether, false);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        _setupStandardQuote(quoteValidUntil + 1, 0.006 ether, 0.004 ether, false);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        _setupStandardQuote((uint256(1) << 248) | (block.number - 1), 0.006 ether, 0.004 ether, false);
        vm.expectRevert(MemoConduit.BridgeQuoteExpired.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        _setupStandardQuote((uint256(2) << 248) | (block.number + 10), 0.006 ether, 0.004 ether, false);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
    }

    function test_bridgeWithMemoCctpX_debitBurnAndNativeBalanceMismatches() public {
        vm.chainId(5042002);
        vm.deal(address(this), 10 ether);
        bytes memory signedQuote = hex"01fedcba";
        uint256 nativeFee = 0.01 ether;
        uint256 quoteValidUntil = block.timestamp + 600;
        _setupStandardQuote(quoteValidUntil, 0.006 ether, 0.004 ether, false);

        MemoConduit.BridgePayment memory bp =
            _eurcBridgePayment(keccak256("cctpx-mis"), signedQuote, nativeFee, quoteValidUntil);
        SpokeMockToken eurc = SpokeMockToken(payable(ARC_TESTNET_EURC));

        eurc.setReceiveMode(3);
        vm.expectRevert(MemoConduit.BridgeDebitMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        eurc.setReceiveMode(4);
        vm.expectRevert(MemoConduit.BridgeDebitMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
        eurc.setReceiveMode(0);

        ccts.setBurnMode(1, payer);
        vm.expectRevert(MemoConduit.BridgeBurnMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        eurc.mint(address(eurcManager), 100e6);
        ccts.setBurnMode(2, payer);
        vm.expectRevert(MemoConduit.BridgeBurnMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        ccts.setBurnMode(3, payer);
        vm.expectRevert(MemoConduit.BridgeBurnMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");

        ccts.setBurnMode(4, payer);
        vm.expectRevert(MemoConduit.BridgeNativeBalanceChanged.selector);
        conduit.bridgeWithMemoCctpX{value: nativeFee}(bp, signedQuote, hex"01");
    }

    function test_spokeMemoConduit_routing() public {
        SpokeMemoConduit spoke = new SpokeMemoConduit(book, _allSupportedTokens(), _defaultConfig());

        require(spoke.hubOf(43114) == 5042, "mainnet spoke");
        require(spoke.hubOf(43113) == 5042002, "testnet spoke");
        require(spoke.hubOf(5042) == 0, "hub is not spoke");
        require(spoke.hubOf(84532) == 0, "base sepolia is not spoke");

        vm.chainId(43114);
        (uint32 sDom, uint32 dDom, address dTok, address msgAddr) = spoke.bridgeRouteOf(1, AVAX_USDC, 5042);
        require(sDom == 1 && dDom == 26 && dTok == ARC_USDC && msgAddr == address(messenger), "spoke mainnet route");

        vm.chainId(5042);
        vm.expectRevert(abi.encodeWithSelector(SpokeMemoConduit.NotSpokeToHub.selector, uint256(5042), uint256(43114)));
        spoke.bridgeRouteOf(1, ARC_USDC, 43114);

        vm.chainId(43113);
        vm.expectRevert(abi.encodeWithSelector(SpokeMemoConduit.NotSpokeToHub.selector, uint256(43113), uint256(84532)));
        spoke.bridgeRouteOf(1, FUJI_USDC, 84532);

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(2)));
        spoke.bridgeRouteOf(2, FUJI_EURC, 5042002);
    }

    function test_spokeMemoConduit_repaymentInitiated() public {
        vm.chainId(43113);
        SpokeMemoConduit spoke = new SpokeMemoConduit(book, _allSupportedTokens(), _defaultConfig());

        MemoConduit.BridgePayment memory bp = MemoConduit.BridgePayment({
            protocol: 1,
            token: FUJI_USDC,
            from: payer,
            recipient: recipient,
            amount: 100e6,
            destinationChainId: 5042002,
            destinationDomain: 26,
            destinationToken: ARC_USDC,
            maxFee: 0,
            minFinalityThreshold: 2000,
            validAfter: 0,
            validBefore: block.timestamp + 1 hours,
            paymentId: keccak256("adv-spoke-1"),
            termsHash: keccak256("mkt-spoke-1"),
            memoId: keccak256("memo-spoke-1"),
            memo: "repay-spoke",
            tokenId: bytes32(0),
            quoteHash: bytes32(0),
            nativeFee: 0,
            quoteValidUntil: 0
        });

        bytes32 authNonce = spoke.bridgePaymentNonceOf(bp);
        bytes32 bridgeNonce = spoke.computeBridgeNonce(bp, authNonce, 26);
        require(bridgeNonce != authNonce, "bridgeNonce distinct");

        _expectSourceBurn(address(spoke), bp, authNonce);
        vm.expectEmit(true, true, true, true, address(spoke));
        emit SpokeMemoConduit.RepaymentInitiated(
            bp.paymentId, bp.termsHash, bp.memoId, payer, recipient, 100e6, 26, bridgeNonce, transmitter
        );
        spoke.bridgeWithMemo(bp, hex"01");
    }
}
