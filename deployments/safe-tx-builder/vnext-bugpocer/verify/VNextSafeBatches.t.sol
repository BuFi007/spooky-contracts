// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

interface IOwnable2StepView {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

interface IConduitView {
    function owner() external view returns (address);
    function targets(address) external view returns (bool);
    function tokens(address) external view returns (bool);
}

interface IConduitPermit2View is IConduitView {
    function permit2() external view returns (address);
    function addressBook() external view returns (address);
    function permit2Routes(address, address) external view returns (bool);
}

interface IBridgeConduitView is IConduitView {
    function bridges(uint8, address) external view returns (bool);
    function cctpxTokens(bytes32) external view returns (address);
    function setCctpxToken(bytes32, address) external;
}

interface IBridgePermit2View is IBridgeConduitView {
    function permit2() external view returns (address);
    function permit2Routes(address, address) external view returns (bool);
}

interface ISwapAndDepositView {
    function owner() external view returns (address);
    function USDC() external view returns (address);
    function venues(address) external view returns (bool);
    function dests(address) external view returns (bool);
}

interface IAccessControlView {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IReputationView is IAccessControlView {
    function IDENTITY() external view returns (address);
    function markRestructured(uint256 sellerAgentId) external;
}

interface ITierRegistryView {
    function IDENTITY() external view returns (address);
    function REPUTATION() external view returns (address);
}

interface IReserveView is IAccessControlView {
    function USDC() external view returns (address);
}

interface IShelfView is IAccessControlView {
    function USDC() external view returns (address);
    function IDENTITY() external view returns (address);
    function REPUTATION() external view returns (address);
    function TIERS() external view returns (address);
    function BINV_TOKEN() external view returns (address);
    function reserve() external view returns (address);
    function escrow() external view returns (address);
    function MIDNIGHT_MODE() external view returns (bool);
}

interface IEscrowView is IAccessControlView {
    function supportedToken(address) external view returns (bool);
}

interface IRouterView is IAccessControlView {
    function SHELF() external view returns (address);
    function ESCROW() external view returns (address);
    function tokenConfig(address) external view returns (bool allowed, uint8 caps);
}

interface IForwarderFactoryView {
    function implementation() external view returns (address);
    function usdc() external view returns (address);
    function tokenMessenger() external view returns (address);
    function predict(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint16 maxFastFeeBps,
        bytes32 documentCommitment
    ) external view returns (address);
}

interface IPeanutV4View is IOwnable2StepView {
    function MFA_AUTHORIZER() external view returns (address);
    function pendingMFAAuthorizer() external view returns (address);
    function mfaAcceptanceDigest(address _newAuthorizer) external view returns (bytes32);
}

interface IPayrollBatchView {
    function PERMIT2() external view returns (address);
    function VAULT() external view returns (address);
}

interface IERC20BalanceView {
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface ICctsLive {
    function resolveTokenManager(bytes32 tokenId) external view returns (address);
    function feeService() external view returns (address);
    function paused() external view returns (bool);
}

interface ITokenManagerLive {
    function token() external view returns (address);
}

interface IFeeManagerLive {
    struct QuoteItem {
        string quoteType;
        bytes32 quoteArgsHash;
        uint256 amount;
    }

    struct Quote {
        QuoteItem[] items;
        uint256 expiry;
        address feeToken;
        uint256 nonce;
        bytes signature;
    }

    struct FeeRequirement {
        string quoteType;
        string[] quoteArgs;
        bool required;
    }

    struct QuoteClaim {
        bytes signedQuote;
        address refundAddress;
    }

    function decodeQuote(bytes calldata signedQuote) external view returns (Quote memory);
    function getQuoteTotal(bytes calldata signedQuote) external view returns (uint256);
    function feeTaker() external view returns (address);
    function feeCollectionAddress() external view returns (address);
    function owner() external view returns (address);
    function setTrustedQuoteSigner(address signer, bool trusted) external;
    function collectFeesWithQuote(bytes32 requestId, FeeRequirement[] calldata requirements, QuoteClaim calldata claim)
        external
        payable
        returns (uint256);
    function paused() external view returns (bool);
}

abstract contract SafeBatchRunner is Test {
    using stdJson for string;

    address internal constant ARACHNID = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes internal constant ARACHNID_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant ADDRESS_BOOK = 0x0000000d81083B16EA76dfab46B0315B0eDBF3d0;

    address internal constant SAFE_ARC = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09;
    address internal constant SAFE_AVAX = 0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B;
    address internal constant MFA_EOA = 0x9c8515333aFdB567C31CDF53CD60868f3B64b724;
    address internal constant KEEPER_EOA = 0xcA02Be6cDBb806d4a327FC92E094D1A44EC37445;

    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant ARC_MAINNET_EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address internal constant ARC_TESTNET_EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address internal constant AVAX_USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant AVAX_EURC = 0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant CCTP_MAINNET = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant CCTPX_MAINNET = 0x431871229103b780868f8C6BB820cd16ECf942BC;
    bytes32 internal constant CCTPX_EURC_MAINNET_ID =
        0x6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2234880da13ca38c657fb241c;

    address internal constant CCTP_TESTNET = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    address internal constant CCTPX_TESTNET = 0x63753E722bd2C2A5DF6EE19C5106662208B81077;
    bytes32 internal constant CCTPX_EURC_TESTNET_ID =
        0x2587821a0ee7daa174b95436b5dab1731cfa1844775b010217d3c0dd02a4eecd;

    address internal constant LIVE_ARC_IDENTITY = 0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d;
    address internal constant LIVE_ARC_REPUTATION = 0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9;
    address internal constant LIVE_ARC_SHELF = 0x90eCDd402C0E357362b7805173191A153b876DF4;

    string internal constant BASE_DIR = "deployments/safe-tx-builder/vnext-bugpocer/";

    function _executeBatchFile(string memory fileName, address callerOverride)
        internal
        returns (uint256 totalGas, uint256 txCount, address safeInFile)
    {
        string memory json = vm.readFile(string.concat(BASE_DIR, fileName));
        safeInFile = json.readAddress(".meta.createdFromSafeAddress");
        address sender = callerOverride == address(0) ? safeInFile : callerOverride;

        while (true) {
            string memory prefix = string.concat(".transactions[", vm.toString(txCount), "]");
            if (!vm.keyExistsJson(json, string.concat(prefix, ".to"))) break;

            address to = json.readAddress(string.concat(prefix, ".to"));
            uint256 val = vm.parseUint(json.readString(string.concat(prefix, ".value")));
            bytes memory data = json.readBytes(string.concat(prefix, ".data"));

            uint256 g0 = gasleft();
            vm.prank(sender);
            (bool ok, bytes memory ret) = to.call{value: val}(data);
            uint256 spent = g0 - gasleft();
            totalGas += spent;

            if (!ok) {
                console2.log("FAILED batch:", fileName);
                console2.log("FAILED tx index:", txCount);
                console2.log("FAILED to:", to);
                console2.logBytes(ret);
                revert("Safe batch tx reverted");
            }

            if (to == ARACHNID) {
                require(ret.length == 20, "Arachnid CREATE2 did not return 20-byte address");
                address deployed;
                assembly {
                    deployed := shr(96, mload(add(ret, 32)))
                }
                address predicted = json.readAddress(string.concat(prefix, ".meta.predictedAddress"));
                assertEq(deployed, predicted, string.concat("CREATE2 address mismatch in ", fileName));
                assertGt(deployed.code.length, 0, "Deployed runtime code is empty");
                assertLe(deployed.code.length, 24_576, "Deployed runtime code exceeds EIP-170");
            }

            txCount++;
        }

        require(txCount > 0, "Batch has zero transactions");
        console2.log(string.concat("[PASS] ", fileName, " | txs="), txCount);
        console2.log("       measured execution gas:", totalGas);
    }

    function _manifestAddr(string memory chainId, string memory key) internal view returns (address) {
        string memory manifest = vm.readFile(string.concat(BASE_DIR, "MANIFEST.json"));
        return manifest.readAddress(string.concat(".chains.", chainId, ".contracts.", key));
    }

    function _etchDummy(address target) internal {
        if (target.code.length == 0) {
            vm.etch(target, hex"60006000fd");
        }
    }
}

contract VNextSafeBatchesOfflineTest is SafeBatchRunner {
    using stdJson for string;

    function setUp() public {
        vm.etch(ARACHNID, ARACHNID_RUNTIME);
        _etchDummy(PERMIT2);
        _etchDummy(ADDRESS_BOOK);
        assertEq(MFA_EOA.code.length, 0, "MFA_EOA must be EOA");
    }

    function test_00_arc5042_hotfix_5_2_2_payload() public view {
        string memory json = vm.readFile(string.concat(BASE_DIR, "00-arc-5042-hotfix-5-2-2-grant-ops-role.json"));
        assertEq(json.readString(".chainId"), "5042");
        assertEq(json.readAddress(".meta.createdFromSafeAddress"), SAFE_ARC);
        assertEq(json.readAddress(".transactions[0].to"), LIVE_ARC_REPUTATION);
        assertEq(
            json.readBytes(".transactions[0].data"),
            abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("OPS_ROLE"), LIVE_ARC_SHELF)
        );
        assertFalse(vm.keyExistsJson(json, ".transactions[1].to"));
    }

    function test_01_arcTestnet_5042002_allBatches() public {
        vm.chainId(5042002);
        address circleAdapter = 0xBBD70b01a1CAbc96d5b7b129Ae1AAabdf50dd40b;
        address lifi = 0xFf70F4A1d11995621854F3692acF286d8aCd04b2;
        address vault = 0x0a9a082C24364B90B73e20E57d7625A3aa798bCa;
        _etchDummy(circleAdapter);
        _etchDummy(lifi);
        _etchDummy(vault);
        _etchDummy(CCTP_TESTNET);
        _etchDummy(CCTPX_TESTNET);

        _executeBatchFile("01a-arc-testnet-5042002-vnext-conduits-v2.json", address(0));
        _executeBatchFile("01b-arc-testnet-5042002-vnext-conduits-v3.json", address(0));
        _executeBatchFile("01c-arc-testnet-5042002-vnext-claim-vault-and-forwarder.json", address(0));

        address tc = _manifestAddr("5042002", "TreasuryConduit");
        address tcp2 = _manifestAddr("5042002", "TreasuryConduitPermit2");
        address tbcv2 = _manifestAddr("5042002", "TreasuryBridgeConduitV2");
        address tcv3 = _manifestAddr("5042002", "TreasuryConduitV3");
        address tbc = _manifestAddr("5042002", "TreasuryBridgeConduit");
        address tbcp2 = _manifestAddr("5042002", "TreasuryBridgeConduitPermit2");
        address tsad = _manifestAddr("5042002", "TreasurySwapAndDeposit");
        address fwdImpl = _manifestAddr("5042002", "CctpDepositForwarderImplementation");
        address fwdFactory = _manifestAddr("5042002", "CctpDepositForwarderFactory");
        address peanut = _manifestAddr("5042002", "PeanutV4");
        address payroll = _manifestAddr("5042002", "PayrollBatch");

        // Token allowlists (5.2.1)
        address[6] memory conduits = [tc, tcp2, tbcv2, tcv3, tbc, tbcp2];
        for (uint256 i; i < conduits.length; ++i) {
            assertEq(IConduitView(conduits[i]).owner(), SAFE_AVAX);
            assertTrue(IConduitView(conduits[i]).tokens(ARC_USDC));
            assertTrue(IConduitView(conduits[i]).tokens(ARC_TESTNET_EURC));
        }

        assertTrue(IConduitView(tc).targets(tsad));
        assertTrue(IConduitView(tcv3).targets(tsad));
        assertTrue(IConduitPermit2View(tcp2).permit2Routes(tsad, tsad));
        assertTrue(IConduitPermit2View(tcp2).permit2Routes(lifi, lifi));

        // Bridges + CCTPx EURC + 0x3600 guard (5.2.5)
        address[3] memory bridges = [tbcv2, tbc, tbcp2];
        for (uint256 i; i < bridges.length; ++i) {
            assertTrue(IBridgeConduitView(bridges[i]).bridges(0, CCTP_TESTNET));
            assertTrue(IBridgeConduitView(bridges[i]).bridges(1, CCTPX_TESTNET));
            assertEq(IBridgeConduitView(bridges[i]).cctpxTokens(CCTPX_EURC_TESTNET_ID), ARC_TESTNET_EURC);
            vm.prank(SAFE_AVAX);
            vm.expectRevert(abi.encodeWithSignature("NativeAssetNotAllowed()"));
            IBridgeConduitView(bridges[i]).setCctpxToken(keccak256("BAD"), ARC_USDC);
        }
        assertTrue(IBridgePermit2View(tbcp2).permit2Routes(CCTP_TESTNET, CCTP_TESTNET));
        assertTrue(IBridgePermit2View(tbcp2).permit2Routes(CCTPX_TESTNET, CCTPX_TESTNET));

        assertEq(ISwapAndDepositView(tsad).owner(), SAFE_AVAX);
        assertEq(ISwapAndDepositView(tsad).USDC(), ARC_USDC);
        assertTrue(ISwapAndDepositView(tsad).venues(circleAdapter));
        assertTrue(ISwapAndDepositView(tsad).venues(lifi));
        assertTrue(ISwapAndDepositView(tsad).dests(vault));

        assertEq(IForwarderFactoryView(fwdFactory).implementation(), fwdImpl);
        assertEq(IForwarderFactoryView(fwdFactory).usdc(), ARC_USDC);
        assertEq(IForwarderFactoryView(fwdFactory).tokenMessenger(), CCTP_TESTNET);
        bytes32 dirtyRecipient = bytes32((uint256(1) << 200) | uint256(uint160(SAFE_AVAX)));
        vm.expectRevert(abi.encodeWithSignature("NonCanonicalMintRecipient(bytes32)", dirtyRecipient));
        IForwarderFactoryView(fwdFactory).predict(1, dirtyRecipient, bytes32(0), 50, keccak256("doc"));

        assertGt(peanut.code.length, 0);
        assertLe(peanut.code.length, 24_576);
        assertEq(IPeanutV4View(peanut).owner(), SAFE_AVAX);
        assertEq(IPeanutV4View(peanut).pendingOwner(), address(0));
        assertEq(IPeanutV4View(peanut).MFA_AUTHORIZER(), MFA_EOA);
        assertEq(IPayrollBatchView(payroll).PERMIT2(), PERMIT2);
        assertEq(IPayrollBatchView(payroll).VAULT(), peanut);
    }

    function test_02_arcMainnet_5042_allBatches() public {
        vm.chainId(5042);
        address lifi = 0xA4072583658Fae592A3506A42431cb6316a8d40b;
        address uniRouter = 0x8702463e73f74d0b6765aBceb314Ef07aCb92650;
        address uniNoP2 = 0x0000000085E102724e78eCd2F45DC9cA239Affad;
        address morphoBitwise = 0x7610094B846657dCF166D59e42973db52c7015F9;
        address morphoSteak = 0xbeef0016cb2Fd5C352ea7CA08a9f54739DFa7298;
        _etchDummy(lifi);
        _etchDummy(uniRouter);
        _etchDummy(uniNoP2);
        _etchDummy(morphoBitwise);
        _etchDummy(morphoSteak);
        _etchDummy(CCTP_MAINNET);
        _etchDummy(CCTPX_MAINNET);
        _etchDummy(LIVE_ARC_IDENTITY);

        _executeBatchFile("02a-arc-5042-vnext-conduits-v2.json", address(0));
        _executeBatchFile("02b-arc-5042-vnext-conduits-v3.json", address(0));
        _executeBatchFile("02c-arc-5042-vnext-fx-hub-part1.json", address(0));
        _executeBatchFile("02d-arc-5042-vnext-fx-hub-part2.json", address(0));
        _executeBatchFile("02e-arc-5042-vnext-claim-vault.json", address(0));

        _assertArcMainnetState();
    }

    function _assertArcMainnetState() internal {
        _assertArcMainnetConduits();
        _assertArcMainnetHub();
        _assertArcMainnetForwarderAndVault();
    }

    function _assertArcMainnetConduits() internal {
        address tc = _manifestAddr("5042", "TreasuryConduit");
        address tcp2 = _manifestAddr("5042", "TreasuryConduitPermit2");
        address tbcv2 = _manifestAddr("5042", "TreasuryBridgeConduitV2");
        address tcv3 = _manifestAddr("5042", "TreasuryConduitV3");
        address tbc = _manifestAddr("5042", "TreasuryBridgeConduit");
        address tbcp2 = _manifestAddr("5042", "TreasuryBridgeConduitPermit2");
        address tsad = _manifestAddr("5042", "TreasurySwapAndDeposit");

        address[6] memory conduits = [tc, tcp2, tbcv2, tcv3, tbc, tbcp2];
        for (uint256 i; i < conduits.length; ++i) {
            assertEq(IConduitView(conduits[i]).owner(), SAFE_ARC);
            assertTrue(IConduitView(conduits[i]).tokens(ARC_USDC));
            assertTrue(IConduitView(conduits[i]).tokens(ARC_MAINNET_EURC));
            assertFalse(IConduitView(conduits[i]).tokens(ARC_TESTNET_EURC));
        }

        assertTrue(IConduitPermit2View(tcp2).permit2Routes(tsad, tsad));
        assertTrue(ISwapAndDepositView(tsad).dests(0x7610094B846657dCF166D59e42973db52c7015F9));
        assertTrue(ISwapAndDepositView(tsad).dests(0xbeef0016cb2Fd5C352ea7CA08a9f54739DFa7298));

        address[3] memory bridges = [tbcv2, tbc, tbcp2];
        for (uint256 i; i < bridges.length; ++i) {
            assertTrue(IBridgeConduitView(bridges[i]).bridges(0, CCTP_MAINNET));
            assertTrue(IBridgeConduitView(bridges[i]).bridges(1, CCTPX_MAINNET));
            assertEq(IBridgeConduitView(bridges[i]).cctpxTokens(CCTPX_EURC_MAINNET_ID), ARC_MAINNET_EURC);
            vm.prank(SAFE_ARC);
            vm.expectRevert(abi.encodeWithSignature("NativeAssetNotAllowed()"));
            IBridgeConduitView(bridges[i]).setCctpxToken(keccak256("BAD"), ARC_USDC);
        }
    }

    function _assertArcMainnetHub() internal view {
        address rep = _manifestAddr("5042", "BUFIReputationRegistry");
        address tiers = _manifestAddr("5042", "WorkspaceTierRegistry");
        address reserve = _manifestAddr("5042", "WorkspaceOperatingReserve");
        address shelf = _manifestAddr("5042", "InvoiceShelf");
        address binv = _manifestAddr("5042", "BINV");
        address bifA = _manifestAddr("5042", "BIFTrancheSenior_bIF_A");
        address bifB = _manifestAddr("5042", "BIFTrancheMezzanine_bIF_B");
        address bifC = _manifestAddr("5042", "BIFTrancheJunior_bIF_C");
        address escrow = _manifestAddr("5042", "MultiTokenReceivableEscrow");
        address router = _manifestAddr("5042", "RecibuMemoRouter");

        assertEq(IReputationView(rep).IDENTITY(), LIVE_ARC_IDENTITY);
        assertTrue(IReputationView(rep).hasRole(keccak256("ATTESTOR_ROLE"), SAFE_ARC));
        assertTrue(IReputationView(rep).hasRole(keccak256("SETTLEMENT_ROLE"), shelf));
        assertTrue(IReputationView(rep).hasRole(keccak256("OPS_ROLE"), shelf));

        assertEq(ITierRegistryView(tiers).IDENTITY(), LIVE_ARC_IDENTITY);
        assertEq(ITierRegistryView(tiers).REPUTATION(), rep);

        assertEq(IReserveView(reserve).USDC(), ARC_USDC);
        assertTrue(IReserveView(reserve).hasRole(keccak256("SHELF_ROLE"), shelf));

        assertEq(IShelfView(shelf).USDC(), ARC_USDC);
        assertEq(IShelfView(shelf).IDENTITY(), LIVE_ARC_IDENTITY);
        assertEq(IShelfView(shelf).REPUTATION(), rep);
        assertEq(IShelfView(shelf).TIERS(), tiers);
        assertEq(IShelfView(shelf).BINV_TOKEN(), binv);
        assertEq(IShelfView(shelf).reserve(), reserve);
        assertEq(IShelfView(shelf).escrow(), escrow);
        assertFalse(IShelfView(shelf).MIDNIGHT_MODE());
        assertTrue(IShelfView(shelf).hasRole(keccak256("SERVICER_ROLE"), SAFE_ARC));
        assertTrue(IShelfView(shelf).hasRole(keccak256("SETTLEMENT_ROLE"), SAFE_ARC));
        assertTrue(IShelfView(shelf).hasRole(keccak256("OPS_ROLE"), KEEPER_EOA));

        assertGt(binv.code.length, 0);
        assertGt(bifA.code.length, 0);
        assertGt(bifB.code.length, 0);
        assertGt(bifC.code.length, 0);

        assertTrue(IEscrowView(escrow).supportedToken(ARC_USDC));
        assertTrue(IEscrowView(escrow).supportedToken(ARC_MAINNET_EURC));
        assertFalse(IEscrowView(escrow).supportedToken(ARC_TESTNET_EURC));
        assertTrue(IEscrowView(escrow).hasRole(keccak256("ROUTER_ROLE"), router));

        assertEq(IRouterView(router).SHELF(), shelf);
        assertEq(IRouterView(router).ESCROW(), escrow);
        (bool uOk, uint8 uCaps) = IRouterView(router).tokenConfig(ARC_USDC);
        (bool eOk, uint8 eCaps) = IRouterView(router).tokenConfig(ARC_MAINNET_EURC);
        assertTrue(uOk);
        assertEq(uCaps, 3);
        assertTrue(eOk);
        assertEq(eCaps, 3);
    }

    function _assertArcMainnetForwarderAndVault() internal view {
        address fwdImpl = _manifestAddr("5042", "CctpDepositForwarderImplementation");
        address fwdFactory = _manifestAddr("5042", "CctpDepositForwarderFactory");
        address peanut = _manifestAddr("5042", "PeanutV4");
        address payroll = _manifestAddr("5042", "PayrollBatch");

        assertEq(IForwarderFactoryView(fwdFactory).implementation(), fwdImpl);
        assertEq(IForwarderFactoryView(fwdFactory).usdc(), ARC_USDC);
        assertEq(IForwarderFactoryView(fwdFactory).tokenMessenger(), CCTP_MAINNET);

        assertGt(peanut.code.length, 0);
        assertLe(peanut.code.length, 24_576);
        assertEq(IPeanutV4View(peanut).owner(), SAFE_ARC);
        assertEq(IPeanutV4View(peanut).pendingOwner(), address(0));
        assertEq(IPeanutV4View(peanut).MFA_AUTHORIZER(), MFA_EOA);
        assertEq(IPayrollBatchView(payroll).PERMIT2(), PERMIT2);
        assertEq(IPayrollBatchView(payroll).VAULT(), peanut);
    }

    function test_03_avalanche_43114_allBatches() public {
        vm.chainId(43114);
        address lifi = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;
        address uniUniv = 0x661E93cca42AfacB172121EF892830cA3b70F08d;
        address uniSR02 = 0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE;
        address uniNoP2 = 0x0000000085E102724e78eCd2F45DC9cA239Affad;
        _etchDummy(lifi);
        _etchDummy(uniUniv);
        _etchDummy(uniSR02);
        _etchDummy(uniNoP2);
        _etchDummy(CCTP_MAINNET);
        _etchDummy(CCTPX_MAINNET);

        _executeBatchFile("03a-avalanche-43114-vnext-conduits-v2.json", address(0));
        _executeBatchFile("03b-avalanche-43114-vnext-conduits-v3-and-forwarder.json", address(0));
        _executeBatchFile("03c-avalanche-43114-vnext-claim-vault.json", address(0));

        address tc = _manifestAddr("43114", "TreasuryConduit");
        address tcp2 = _manifestAddr("43114", "TreasuryConduitPermit2");
        address tbcv2 = _manifestAddr("43114", "TreasuryBridgeConduitV2");
        address tbc = _manifestAddr("43114", "TreasuryBridgeConduit");
        address tbcp2 = _manifestAddr("43114", "TreasuryBridgeConduitPermit2");
        address fwdImpl = _manifestAddr("43114", "CctpDepositForwarderImplementation");
        address fwdFactory = _manifestAddr("43114", "CctpDepositForwarderFactory");
        address peanut = _manifestAddr("43114", "PeanutV4");
        address payroll = _manifestAddr("43114", "PayrollBatch");

        // Cross-chain CREATE2 parity with Arc Testnet (same Safe 0xA3a4...468B)
        assertEq(tc, _manifestAddr("5042002", "TreasuryConduit"));
        assertEq(peanut, _manifestAddr("5042002", "PeanutV4"));
        assertEq(payroll, _manifestAddr("5042002", "PayrollBatch"));
        assertEq(fwdImpl, _manifestAddr("5042", "CctpDepositForwarderImplementation"));

        address[5] memory conduits = [tc, tcp2, tbcv2, tbc, tbcp2];
        for (uint256 i; i < conduits.length; ++i) {
            assertEq(IConduitView(conduits[i]).owner(), SAFE_AVAX);
            assertTrue(IConduitView(conduits[i]).tokens(AVAX_USDC));
            assertTrue(IConduitView(conduits[i]).tokens(AVAX_EURC));
            assertTrue(IConduitView(conduits[i]).targets(lifi));
            assertTrue(IConduitView(conduits[i]).targets(uniNoP2));
        }
        address[3] memory bridges = [tbcv2, tbc, tbcp2];
        for (uint256 i; i < bridges.length; ++i) {
            assertTrue(IBridgeConduitView(bridges[i]).bridges(0, CCTP_MAINNET));
            assertTrue(IBridgeConduitView(bridges[i]).bridges(1, CCTPX_MAINNET));
            assertEq(IBridgeConduitView(bridges[i]).cctpxTokens(CCTPX_EURC_MAINNET_ID), AVAX_EURC);
        }

        assertEq(IForwarderFactoryView(fwdFactory).implementation(), fwdImpl);
        assertEq(IForwarderFactoryView(fwdFactory).usdc(), AVAX_USDC);
        assertEq(IForwarderFactoryView(fwdFactory).tokenMessenger(), CCTP_MAINNET);
        assertEq(IPeanutV4View(peanut).owner(), SAFE_AVAX);
        assertEq(IPayrollBatchView(payroll).VAULT(), peanut);
    }

    function test_04_base_8453_allBatches_includingMultiSendSplit() public {
        vm.chainId(8453);
        address multiSendCallOnly = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;

        // 04a can be executed by MultiSendCallOnly (or any EOA) even before Safe 0x47Dc...0D09 is deployed on Base
        _executeBatchFile("04a-base-8453-vnext-cctp-forwarder-and-claim-vault.json", multiSendCallOnly);

        address fwdImpl = _manifestAddr("8453", "CctpDepositForwarderImplementation");
        address fwdFactory = _manifestAddr("8453", "CctpDepositForwarderFactory");
        address cvd = _manifestAddr("8453", "ClaimVaultDeployer");
        address peanut = _manifestAddr("8453", "PeanutV4");
        address payroll = _manifestAddr("8453", "PayrollBatch");

        // Cross-chain CREATE2 parity with Arc Mainnet (same Safe 0x47Dc...0D09)
        assertEq(peanut, _manifestAddr("5042", "PeanutV4"));
        assertEq(payroll, _manifestAddr("5042", "PayrollBatch"));
        assertEq(IForwarderFactoryView(fwdFactory).implementation(), fwdImpl);
        assertEq(IForwarderFactoryView(fwdFactory).usdc(), BASE_USDC);
        assertEq(IForwarderFactoryView(fwdFactory).tokenMessenger(), CCTP_MAINNET);

        // Before 04b, ClaimVaultDeployer still holds owner and Safe is pendingOwner
        assertEq(IPeanutV4View(peanut).owner(), cvd);
        assertEq(IPeanutV4View(peanut).pendingOwner(), SAFE_ARC);

        // 04b runs from Base Safe 0x47Dc...0D09 once deployed
        _executeBatchFile("04b-base-8453-vnext-claim-vault-accept-ownership.json", address(0));
        assertEq(IPeanutV4View(peanut).owner(), SAFE_ARC);
        assertEq(IPeanutV4View(peanut).pendingOwner(), address(0));
        assertEq(IPeanutV4View(peanut).MFA_AUTHORIZER(), MFA_EOA);
        assertEq(IPayrollBatchView(payroll).VAULT(), peanut);
    }
}

contract VNextArcMainnetForkTest is SafeBatchRunner {
    // Real 929-byte IRIS-signed CCTPx quote extracted from live Fuji tx 0x341392ea...0f46f
    bytes internal constant REAL_IRIS_QUOTE =
        hex"01000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000006ad5242a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000000000000000000000000000000000000000006076c89b4f32e3caf74e37e9f6cd4c83b8ada06c21b33d8ff8a1dcdbeb64c98a59000000000000000000000000000000000000000000000000006091ab2a807ee20000000000000000000000000000000000000000000000000000000000000007464f5257415244000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060b345cfda326b4981c427cc98dc7cc4708217a3bd0ae17fab92d4e4c3ab2b5e53000000000000000000000000000000000000000000000000000036cbe9e0822f000000000000000000000000000000000000000000000000000000000000000c5052455f46494e414c495459000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000602df81ca80be1f28bbdad5be0ae6b6aca42d87a850f805f95a0b696d850bd5ca10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000850524f544f434f4c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000414ffdcde2698b64c3247ed7ccd55b68e71cb501acf5fff2e098ff100f15cf1fa02c3affbfb8e25af0a05513cc7243ef6cecbca35abbaae5146f6db99123f802cc1c00000000000000000000000000000000000000000000000000000000000000";

    bool internal forkActive;

    function setUp() public {
        forkActive = vm.envOr("ARC_MAINNET_FORK", false);
        if (!forkActive) return;
        vm.createSelectFork(vm.envString("ARC_MAINNET_RPC_URL"));
        vm.setEvmVersion("prague");
        require(block.chainid == 5042, "Fork is not Arc Mainnet 5042");
    }

    function test_liveFork_00_hotfix_5_2_2_grantOpsRole_and_markRestructured() public {
        if (!forkActive) return;
        bytes32 opsRole = keccak256("OPS_ROLE");
        IReputationView rep = IReputationView(LIVE_ARC_REPUTATION);

        // Before hotfix: live Nov 7 InvoiceShelf lacks OPS_ROLE (BugPoCer 5.2.2)
        assertFalse(rep.hasRole(opsRole, LIVE_ARC_SHELF), "Expected live 5.2.2 defect before hotfix");
        vm.prank(LIVE_ARC_SHELF);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", LIVE_ARC_SHELF, opsRole)
        );
        rep.markRestructured(1);

        // Execute exact Safe Transaction Builder JSON batch 00 from live Safe 0x47Dc...0D09
        _executeBatchFile("00-arc-5042-hotfix-5-2-2-grant-ops-role.json", address(0));

        // After hotfix: live Nov 7 InvoiceShelf holds OPS_ROLE and passes role gate
        assertTrue(rep.hasRole(opsRole, LIVE_ARC_SHELF), "OPS_ROLE grant failed");
        vm.prank(LIVE_ARC_SHELF);
        (bool ok, bytes memory ret) = LIVE_ARC_REPUTATION.call(
            abi.encodeWithSignature("markRestructured(uint256)", uint256(999_999))
        );
        // Must NOT revert with AccessControlUnauthorizedAccount(address,bytes32) = 0xe2517d3f
        if (!ok && ret.length >= 4) {
            bytes4 errSel;
            assembly {
                errSel := mload(add(ret, 32))
            }
            assertTrue(errSel != bytes4(0xe2517d3f), "Still failed AccessControlUnauthorizedAccount");
            console2.log("markRestructured passed OPS_ROLE gate and hit domain error selector:");
            console2.logBytes4(errSel);
        } else {
            assertTrue(ok, "markRestructured succeeded cleanly");
        }
    }

    function test_liveFork_02_arcMainnet_allVNextBatches_againstLiveContracts() public {
        if (!forkActive) return;

        // Ensure real live dependencies exist on Arc Mainnet 5042 without mocking
        assertGt(ARACHNID.code.length, 0);
        assertGt(PERMIT2.code.length, 0);
        assertGt(ADDRESS_BOOK.code.length, 0);
        assertGt(ARC_MAINNET_EURC.code.length, 0);
        assertEq(ARC_TESTNET_EURC.code.length, 0, "Old Nov 7 Arc EURC must have 0 bytes on mainnet");
        assertGt(LIVE_ARC_IDENTITY.code.length, 0);
        assertEq(MFA_EOA.code.length, 0);

        (uint256 g2a,,) = _executeBatchFile("02a-arc-5042-vnext-conduits-v2.json", address(0));
        (uint256 g2b,,) = _executeBatchFile("02b-arc-5042-vnext-conduits-v3.json", address(0));
        (uint256 g2c,,) = _executeBatchFile("02c-arc-5042-vnext-fx-hub-part1.json", address(0));
        (uint256 g2d,,) = _executeBatchFile("02d-arc-5042-vnext-fx-hub-part2.json", address(0));
        (uint256 g2e,,) = _executeBatchFile("02e-arc-5042-vnext-claim-vault.json", address(0));

        console2.log("LIVE FORK GAS SUMMARY:");
        console2.log("  02a conduits-v2:", g2a);
        console2.log("  02b conduits-v3:", g2b);
        console2.log("  02c fx-hub-part1:", g2c);
        console2.log("  02d fx-hub-part2:", g2d);
        console2.log("  02e claim-vault:", g2e);

        address rep = _manifestAddr("5042", "BUFIReputationRegistry");
        address shelf = _manifestAddr("5042", "InvoiceShelf");
        assertTrue(IReputationView(rep).hasRole(keccak256("OPS_ROLE"), shelf));
        assertTrue(IReputationView(rep).hasRole(keccak256("SETTLEMENT_ROLE"), shelf));

        address tbc = _manifestAddr("5042", "TreasuryBridgeConduit");
        assertTrue(IBridgeConduitView(tbc).tokens(ARC_USDC));
        assertTrue(IBridgeConduitView(tbc).tokens(ARC_MAINNET_EURC));
        assertEq(IBridgeConduitView(tbc).cctpxTokens(CCTPX_EURC_MAINNET_ID), ARC_MAINNET_EURC);

        address peanut = _manifestAddr("5042", "PeanutV4");
        assertEq(IPeanutV4View(peanut).owner(), SAFE_ARC);
        assertEq(IPeanutV4View(peanut).MFA_AUTHORIZER(), MFA_EOA);
    }

    function test_liveFork_arcPrecompile_and_liveCctpxFeeManager() public view {
        if (!forkActive) return;

        // 1. Live Arc 0x3600... USDC precompile metadata & exact floor behavior
        assertEq(IERC20BalanceView(ARC_USDC).decimals(), 6);
        assertEq(IERC20BalanceView(ARC_USDC).symbol(), "USDC");
        assertEq(IERC20BalanceView(ARC_MAINNET_EURC).decimals(), 6);
        assertEq(IERC20BalanceView(ARC_MAINNET_EURC).symbol(), "EURC");

        // Note: revm does not execute Arc's custom 0x1800... precompile inside balanceOf() on fork;
        // we verify live native balance parity separately via eth_call against the live Arc RPC node,
        // and verify live CCTPx FeeManager + TokenManager directly on the fork here.
        ICctsLive ccts = ICctsLive(CCTPX_MAINNET);
        assertFalse(ccts.paused(), "Live CCTPx CCTS paused");
        address tokenMgr = ccts.resolveTokenManager(CCTPX_EURC_MAINNET_ID);
        assertEq(tokenMgr, 0x8c27579e24F9f19D96724e19fC059dAcd1469e10);
        assertEq(ITokenManagerLive(tokenMgr).token(), ARC_MAINNET_EURC, "CCTPx EURC token mismatch");

        address feeMgrAddr = ccts.feeService();
        assertEq(feeMgrAddr, 0x88e0FEE76fE71F467009DFddcfa759dDc6B1a575);
        IFeeManagerLive feeMgr = IFeeManagerLive(feeMgrAddr);
        assertFalse(feeMgr.paused(), "Live CCTPx FeeManager paused");

        IFeeManagerLive.Quote memory q = feeMgr.decodeQuote(REAL_IRIS_QUOTE);
        assertEq(q.items.length, 3);
        assertEq(q.items[0].quoteType, "FORWARD");
        assertEq(q.items[0].amount, 27_181_762_102_722_274);
        assertEq(q.items[1].quoteType, "PRE_FINALITY");
        assertEq(q.items[1].amount, 60_249_430_065_711);
        assertEq(q.items[2].quoteType, "PROTOCOL");
        assertEq(q.items[2].amount, 0);
        assertEq(q.expiry, 1_792_353_322);
        assertEq(q.feeToken, address(0));
        assertEq(q.nonce, 0);
        assertEq(q.signature.length, 65);
        assertEq(
            feeMgr.getQuoteTotal(REAL_IRIS_QUOTE),
            27_181_762_102_722_274 + 60_249_430_065_711,
            "getQuoteTotal mismatch"
        );
        address liveFeeTaker = feeMgr.feeTaker();
        assertEq(liveFeeTaker, 0xf992EFCB5FA2eD7cB48310D9dd8Cb4ce5FB7DdC9, "Unexpected FeeManager.feeTaker");
        address collector = feeMgr.feeCollectionAddress();
        assertTrue(collector != address(0), "FeeManager.feeCollectionAddress is zero");
        console2.log("Live Arc FeeManager feeTaker:", liveFeeTaker);
        console2.log("Live Arc FeeManager feeCollectionAddress:", collector);
        console2.log("Live Arc FeeManager getQuoteTotal(realIrisQuote):", feeMgr.getQuoteTotal(REAL_IRIS_QUOTE));
    }

    function test_liveFork_cctpxFeeManager_excessValueRefundMechanics() public {
        if (!forkActive) return;
        IFeeManagerLive feeMgr = IFeeManagerLive(ICctsLive(CCTPX_MAINNET).feeService());
        address collector = feeMgr.feeCollectionAddress();
        address refundRecipient = makeAddr("cctpxRefundRecipient");

        // revm does not implement Arc's 0x1800...0001 native blocklist precompile called by 0x3600.isBlacklisted()
        vm.mockCall(
            address(0x1800000000000000000000000000000000000001),
            abi.encodeWithSelector(bytes4(keccak256("isBlocklisted(address)"))),
            abi.encode(false)
        );

        // Grant QUOTE_SIGNER_ADMIN role (0x6f82...) via OZ AccessControl on the fork to trust our ephemeral test signer
        uint256 signerPk = 0xA11CE;
        address signer = vm.addr(signerPk);
        bytes32 quoteRole = 0x6f82f19233637990cc5fee2a338f11530b99de438ca6f1e3226d1410814c055e;
        bytes32 acSlot = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;
        bytes32 roleMapSlot = keccak256(abi.encode(quoteRole, acSlot));
        vm.store(address(feeMgr), keccak256(abi.encode(feeMgr.owner(), roleMapSlot)), bytes32(uint256(1)));
        vm.prank(feeMgr.owner());
        feeMgr.setTrustedQuoteSigner(signer, true);

        // First probe with dummy sig on a live quote to confirm FeeManager signature verification + collectFeesWithQuote path
        IFeeManagerLive.FeeRequirement[] memory reqs = new IFeeManagerLive.FeeRequirement[](1);
        reqs[0] = IFeeManagerLive.FeeRequirement({quoteType: "PROTOCOL", quoteArgs: new string[](0), required: true});

        uint256 feeAmt = 1e15;
        uint256 excess = 7e14;
        IFeeManagerLive.QuoteItem[] memory items = new IFeeManagerLive.QuoteItem[](1);
        items[0] = IFeeManagerLive.QuoteItem({
            quoteType: "PROTOCOL",
            quoteArgsHash: keccak256(abi.encode(reqs[0].quoteArgs)),
            amount: feeAmt
        });
        uint256 expiry = block.timestamp + 3600;
        // Dummy non-zero valid-looking (r, s, v=27) so OZ ECDSA reaches precompile 0x01
        bytes memory dummySig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1)), uint8(27));
        IFeeManagerLive.Quote memory dummyQuote = IFeeManagerLive.Quote({
            items: items,
            expiry: expiry,
            feeToken: address(0),
            nonce: 0,
            signature: dummySig
        });
        bytes memory probeBytes = abi.encodePacked(uint8(1), abi.encode(dummyQuote));
        IFeeManagerLive.Quote memory decoded = feeMgr.decodeQuote(probeBytes);
        assertEq(decoded.items.length, 1);
        assertEq(decoded.items[0].amount, feeAmt);

        // Probe once to capture the deterministic EIP-712 signer recovered by live FeeManager for dummySig
        vm.deal(CCTPX_MAINNET, (feeAmt + excess) * 2);
        vm.prank(CCTPX_MAINNET);
        (bool probeOk, bytes memory probeRet) = address(feeMgr).call{value: feeAmt + excess}(
            abi.encodeWithSelector(
                IFeeManagerLive.collectFeesWithQuote.selector,
                keccak256("probe-req"),
                reqs,
                IFeeManagerLive.QuoteClaim({signedQuote: probeBytes, refundAddress: refundRecipient})
            )
        );
        assertFalse(probeOk, "Unsigned probe must revert InvalidQuoteSigner");
        assertEq(bytes4(probeRet), bytes4(0x9f6905a9), "Expected InvalidQuoteSigner(address)");
        address recoveredSigner;
        assembly {
            recoveredSigner := and(mload(add(probeRet, 36)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
        vm.prank(feeMgr.owner());
        feeMgr.setTrustedQuoteSigner(recoveredSigner, true);

        // 1. Live Arc FeeManager rejects excess msg.value with IncorrectNativePayment(expected, actual)
        vm.prank(CCTPX_MAINNET);
        (bool overOk, bytes memory overRet) = address(feeMgr).call{value: feeAmt + excess}(
            abi.encodeWithSelector(
                IFeeManagerLive.collectFeesWithQuote.selector,
                keccak256("probe-req"),
                reqs,
                IFeeManagerLive.QuoteClaim({signedQuote: probeBytes, refundAddress: refundRecipient})
            )
        );
        assertFalse(overOk, "Expected IncorrectNativePayment on excess msg.value");
        assertEq(
            overRet,
            abi.encodeWithSignature("IncorrectNativePayment(uint256,uint256)", feeAmt, feeAmt + excess),
            "Unexpected revert on excess msg.value"
        );

        // 2. Live Arc FeeManager rejects short msg.value with IncorrectNativePayment(expected, actual)
        vm.prank(CCTPX_MAINNET);
        (bool underOk, bytes memory underRet) = address(feeMgr).call{value: feeAmt - 1}(
            abi.encodeWithSelector(
                IFeeManagerLive.collectFeesWithQuote.selector,
                keccak256("probe-req"),
                reqs,
                IFeeManagerLive.QuoteClaim({signedQuote: probeBytes, refundAddress: refundRecipient})
            )
        );
        assertFalse(underOk, "Expected IncorrectNativePayment on short msg.value");
        assertEq(
            underRet,
            abi.encodeWithSignature("IncorrectNativePayment(uint256,uint256)", feeAmt, feeAmt - 1),
            "Unexpected revert on short msg.value"
        );

        // 3. Exact msg.value == feeAmt succeeds, routes exact feeAmt to feeCollectionAddress,
        //    retains 0 wei in FeeManager, and returns 0 wei to caller (preserving conduit nativeBefore)
        uint256 collectorBefore = collector.balance;
        uint256 feeMgrBefore = address(feeMgr).balance;
        uint256 callerBefore = CCTPX_MAINNET.balance;
        vm.prank(CCTPX_MAINNET);
        (bool ok, bytes memory ret) = address(feeMgr).call{value: feeAmt}(
            abi.encodeWithSelector(
                IFeeManagerLive.collectFeesWithQuote.selector,
                keccak256("probe-req"),
                reqs,
                IFeeManagerLive.QuoteClaim({signedQuote: probeBytes, refundAddress: refundRecipient})
            )
        );
        if (!ok) {
            console2.log("collectFeesWithQuote reverted:");
            console2.logBytes(ret);
        }
        assertTrue(ok, "Live Arc FeeManager.collectFeesWithQuote exact payment failed");
        assertEq(collector.balance - collectorBefore, feeAmt, "Collector did not receive exact feeAmt");
        assertEq(refundRecipient.balance, 0, "Exact payment should not refund");
        assertEq(address(feeMgr).balance, feeMgrBefore, "FeeManager retained wei");
        assertEq(callerBefore - CCTPX_MAINNET.balance, feeAmt, "Caller balance delta != feeAmt");
        console2.log("LIVE ARC FEEMANAGER VERIFIED:");
        console2.log("  excess/short msg.value revert: IncorrectNativePayment(uint256,uint256)");
        console2.log("  exact payment routed to feeCollectionAddress:", collector.balance - collectorBefore);
        console2.log("  net wei retained by FeeManager:", address(feeMgr).balance - feeMgrBefore);
    }
}
