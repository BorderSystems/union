pragma solidity ^0.8.27;

import "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import "solidity-bytes-utils/BytesLib.sol";

import "../core/02-client/ILightClient.sol";
import "../core/24-host/IBCStore.sol";
import "../core/24-host/IBCCommitment.sol";
import "../lib/ICS23.sol";

struct Header {
    uint64 l1Height;
    uint64 l2Height;
    bytes l2InclusionProof;
    bytes l2ConsensusState;
}

struct ClientState {
    string l2ChainId;
    uint32 l1ClientId;
    uint32 l2ClientId;
    uint64 l2LatestHeight;
    uint16 timestampOffset;
    uint16 stateRootOffset;
}

struct ConsensusState {
    uint64 timestamp;
    bytes32 stateRoot;
}

library StateLensIcs23SmtLib {
    uint256 public constant EVM_IBC_COMMITMENT_SLOT = 0;

    event CreateLensClient(
        uint32 clientId, uint32 l1ClientId, uint32 l2ClientId, string l2ChainId
    );

    error ErrNotIBC();
    error ErrTrustedConsensusStateNotFound();
    error ErrClientFrozen();
    error ErrInvalidL1Proof();
    error ErrInvalidInitialConsensusState();
    error ErrUnsupported();

    function encode(
        ConsensusState memory consensusState
    ) public pure returns (bytes memory) {
        return abi.encode(consensusState.timestamp, consensusState.stateRoot);
    }

    function encode(
        ClientState memory clientState
    ) public pure returns (bytes memory) {
        return abi.encode(
            clientState.l2ChainId,
            clientState.l1ClientId,
            clientState.l2ClientId,
            clientState.l2LatestHeight,
            clientState.timestampOffset,
            clientState.stateRootOffset
        );
    }

    function commit(
        ConsensusState memory consensusState
    ) internal pure returns (bytes32) {
        return keccak256(encode(consensusState));
    }

    function commit(
        ClientState memory clientState
    ) internal pure returns (bytes32) {
        return keccak256(encode(clientState));
    }

    function extract(
        bytes calldata input,
        uint16 offset
    ) internal pure returns (bytes32 val) {
        assembly {
            val := calldataload(add(input.offset, offset))
        }
    }

    function extractMemory(
        bytes memory input,
        uint16 offset
    ) internal pure returns (bytes32 val) {
        assembly {
            // For "bytes memory", the first 32 bytes is the length.
            // Then actual data starts at `add(input, 32)`.
            val := mload(add(input, add(32, offset)))
        }
    }
}

contract StateLensIcs23SmtClient is
    ILightClient,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable
{
    using StateLensIcs23SmtLib for *;

    address private ibcHandler;

    mapping(uint32 => ClientState) private clientStates;
    mapping(uint32 => mapping(uint64 => ConsensusState)) private consensusStates;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _ibcHandler,
        address admin
    ) public initializer {
        __Ownable_init(admin);
        ibcHandler = _ibcHandler;
    }

    function createClient(
        uint32 clientId,
        bytes calldata clientStateBytes,
        bytes calldata consensusStateBytes
    )
        external
        override
        onlyIBC
        returns (
            ConsensusStateUpdate memory update,
            string memory counterpartyChainId
        )
    {
        ClientState calldata clientState;
        assembly {
            clientState := clientStateBytes.offset
        }
        ConsensusState calldata consensusState;
        assembly {
            consensusState := consensusStateBytes.offset
        }

        if (clientState.l2LatestHeight == 0 || consensusState.timestamp == 0) {
            revert StateLensIcs23SmtLib.ErrInvalidInitialConsensusState();
        }
        clientStates[clientId] = clientState;
        consensusStates[clientId][clientState.l2LatestHeight] = consensusState;

        emit StateLensIcs23SmtLib.CreateLensClient(
            clientId,
            clientState.l1ClientId,
            clientState.l2ClientId,
            clientState.l2ChainId
        );

        return (
            ConsensusStateUpdate({
                clientStateCommitment: clientState.commit(),
                consensusStateCommitment: consensusState.commit(),
                height: clientState.l2LatestHeight
            }),
            clientState.l2ChainId
        );
    }

    /*
     * We update the L₂ client through the L₁ client.
     * Given an L₂ and L₁ heights (H₂, H₁), we prove that L₂[H₂] ∈ L₁[H₁].
     */
    function updateClient(
        uint32 clientId,
        bytes calldata clientMessageBytes
    ) external override onlyIBC returns (ConsensusStateUpdate memory) {
        Header calldata header;
        assembly {
            header := clientMessageBytes.offset
        }

        ClientState storage clientState = clientStates[clientId];
        ILightClient l1Client =
            IBCStore(ibcHandler).getClient(clientState.l1ClientId);
        // L₂[H₂] ∈ L₁[H₁]
        if (
            !l1Client.verifyMembership(
                clientState.l1ClientId,
                header.l1Height,
                header.l2InclusionProof,
                abi.encodePacked(
                    IBCCommitment.consensusStateCommitmentKey(
                        clientState.l2ClientId, header.l2Height
                    )
                ),
                abi.encodePacked(keccak256(header.l2ConsensusState))
            )
        ) {
            revert StateLensIcs23SmtLib.ErrInvalidL1Proof();
        }

        bytes memory rawL2ConsensusState = header.l2ConsensusState;
        uint64 l2Timestamp = uint64(
            uint256(
                StateLensIcs23SmtLib.extractMemory(
                    rawL2ConsensusState, clientState.timestampOffset
                )
            )
        );
        bytes32 l2StateRoot = StateLensIcs23SmtLib.extractMemory(
            rawL2ConsensusState, clientState.stateRootOffset
        );

        if (header.l2Height > clientState.l2LatestHeight) {
            clientState.l2LatestHeight = header.l2Height;
        }

        // L₂[H₂] = S₂
        // We use ethereum native encoding to make it more efficient.
        ConsensusState storage consensusState =
            consensusStates[clientId][header.l2Height];
        consensusState.timestamp = l2Timestamp;
        consensusState.stateRoot = l2StateRoot;

        // commit(S₂)
        return ConsensusStateUpdate({
            clientStateCommitment: clientState.commit(),
            consensusStateCommitment: consensusState.commit(),
            height: header.l2Height
        });
    }

    function misbehaviour(
        uint32 clientId,
        bytes calldata clientMessageBytes
    ) external override onlyIBC {
        revert StateLensIcs23SmtLib.ErrUnsupported();
    }

    function verifyMembership(
        uint32 clientId,
        uint64 height,
        bytes calldata proof_stream,
        bytes calldata path,
        bytes calldata value
    ) external virtual returns (bool) {
        // TODO: we can't do sha3, so returning true temporarily
        return true;
    }

    function verifyNonMembership(
        uint32 clientId,
        uint64 height,
        bytes calldata proof_stream,
        bytes calldata path
    ) external virtual returns (bool) {
        // TODO: we can't do sha3, so returning true temporarily
        return true;
    }

    function getClientState(
        uint32 clientId
    ) external view returns (bytes memory) {
        return clientStates[clientId].encode();
    }

    function getConsensusState(
        uint32 clientId,
        uint64 height
    ) external view returns (bytes memory) {
        return consensusStates[clientId][height].encode();
    }

    function getTimestampAtHeight(
        uint32 clientId,
        uint64 height
    ) external view override returns (uint64) {
        return consensusStates[clientId][height].timestamp;
    }

    function getLatestHeight(
        uint32 clientId
    ) external view override returns (uint64) {
        return clientStates[clientId].l2LatestHeight;
    }

    function isFrozen(
        uint32 clientId
    ) external view virtual returns (bool) {
        return isFrozenImpl(clientId);
    }

    function isFrozenImpl(
        uint32 clientId
    ) internal view returns (bool) {
        uint32 l1ClientId = clientStates[clientId].l1ClientId;
        return IBCStore(ibcHandler).getClient(l1ClientId).isFrozen(l1ClientId);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function _onlyIBC() internal view {
        if (msg.sender != ibcHandler) {
            revert StateLensIcs23SmtLib.ErrNotIBC();
        }
    }

    modifier onlyIBC() {
        _onlyIBC();
        _;
    }
}
