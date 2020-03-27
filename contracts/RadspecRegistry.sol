pragma solidity ^0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";

import "./InterfacesV4/IArbitrator.sol";
import "./InterfacesV4/IArbitrable.sol";

import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/lib/math/SafeMath64.sol";

contract RadspecRegistry is IArbitrable, AragonApp {
    using SafeMath for uint256;
    using SafeMath64 for uint64;

    // Roles
    bytes32 public constant SET_BENEFICIARY_ROLE = keccak256("SET_BENEFICIARY_ROLE");
    bytes32 public constant SET_FEE_PERCENTAGE_ROLE = keccak256("SET_FEE_PERCENTAGE_ROLE");
    bytes32 public constant SET_ARBITRATOR_ROLE = keccak256("SET_ARBITRATOR_ROLE");
    bytes32 public constant SET_UPSERT_FEE_ROLE = keccak256("SET_UPSERT_FEE_ROLE");
    bytes32 public constant STAKED_UPSERT_ENTRY_ROLE = keccak256("STAKED_UPSERT_ENTRY_ROLE");
    bytes32 public constant UPSERT_ENTRY_ROLE = keccak256("UPSERT_ENTRY_ROLE");
    bytes32 public constant REMOVE_ENTRY_ROLE = keccak256("REMOVE_ENTRY_ROLE");

    // Error codes
    string public constant ERROR_FEE_PCT_TOO_BIG = "ERROR_FEE_PCT_TOO_BIG";
    string public constant ERROR_INCORRECT_STAKE_AMOUNT = "ERROR_INCORRECT_STAKE_AMOUNT";
    string public constant ERROR_DISPUTE_EXISTS = "ERROR_DISPUTE_EXISTS";
    string public constant ERROR_DISPUTE_DOESNT_EXIST = "ERROR_DISPUTE_DOESNT_EXIST";
    string public constant ERROR_ENTRY_DOESNT_EXIST = "ERROR_ENTRY_DOESNT_EXIST";
    string public constant ERROR_NOT_ARBITRATOR = "ERROR_NOT_ARBITRATOR";
    string public constant ERROR_ETH_TRANSFER_FAILED = "ERROR_ETH_TRANSFER_FAILED";

    // Misc constants
    uint64 public constant PCT_BASE = 10 ** 18; // 0% = 0; 1% = 10^16; 100% = 10^18

    // Storage
    struct Entry {
        uint256 stake;
        string cid; // Content identifier
        address submitter;
        uint256 disputeId;
    }

    struct DisputeInfo {
        address creator;
        address scope;
        bytes4 sig;
    }

    /**
     * Mapping of scope -> sig -> entry
     */
    mapping(address => mapping(bytes4 => Entry)) internal entries;

    /**
     * Mapping of disputeId -> disputeInfo
     */
    mapping(uint256 => DisputeInfo) internal disputes;

    IArbitrator public arbitrator;
    address public beneficiary;
    uint64 public feePct;
    uint256 public claimableFees;
    uint256 public upsertFee;

    /**
     * @dev Emitted when an entry is inserted or updated.
     * @param scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param sig The signature of the method the entry is describing.
     * @param submitter The address that upserted the entry.
     * @param stake The stake that was used to upsert the entry.
     * @param cid The IPFS CID of the file containing the Radspec description.
     */
    event EntryUpserted(address indexed scope, bytes4 indexed sig, address submitter, uint256 stake, string cid);

    /**
     * @dev Emitted when an entry is removed.
     * @param scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param sig The signature of the method the entry is describing.
     */
    event EntryRemoved(address indexed scope, bytes4 indexed sig);

    /**
     * @dev Emitted when a dispute for an entry is created.
     * @param scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param sig The signature of the method the entry is describing.
     * @param disputeId The Aragon Court dispute ID for the dispute.
     */
    event EntryDisputed(address indexed scope, bytes4 indexed sig, uint256 disputeId);

    /**
     * @dev Emitted when fees are claimed.
     * @param feesClaimed The value of the fees claimed.
     */
    event FeesClaimed(uint256 feesClaimed);

    /**
     * @dev Initializes the registry.
     * @param _arbitrator The arbitrator of the registry.
     * @param _feePct The percentage of stakes sent to `_beneficiary`
     * @param _beneficiary The beneficiary of registry fees
     * @param _upsertFee The fee upserting an entry
     */
    function initialize(IArbitrator _arbitrator, uint64 _feePct, address _beneficiary, uint256 _upsertFee)
        external
        onlyInit
    {
        initialized();

        require(_feePct <= PCT_BASE, ERROR_FEE_PCT_TOO_BIG);

        arbitrator = _arbitrator;
        feePct = _feePct;
        beneficiary = _beneficiary;
        upsertFee = _upsertFee;
    }

    /**
     * @dev Set the arbitrator of the registry.
     * @param _arbitrator The arbitrator of the registry.
     */
    function setArbitrator(IArbitrator _arbitrator)
        external
        auth(SET_ARBITRATOR_ROLE)
    {
        arbitrator = _arbitrator;
    }

    /**
     * @dev Set fee perecentage of the registry.
     * @param _feePct The percentage of stakes sent to `beneficiary`
     */
    function setFeePct(uint64 _feePct)
        external
        auth(SET_FEE_PERCENTAGE_ROLE)
    {
        require(_feePct <= PCT_BASE, ERROR_FEE_PCT_TOO_BIG);
        feePct = _feePct;
    }

    /**
     * @dev Set beneficiary of registry fees.
     * @param _beneficiary The beneficiary of registry fees
     */
    function setBeneficiary(address _beneficiary)
        external
        auth(SET_BENEFICIARY_ROLE)
    {
        beneficiary = _beneficiary;
    }

    /**
    * @dev Set the fee for upserting.
    * @param _upsertFee The beneficiary of registry fees
    */
    function setUpsertFee(uint256 _upsertFee)
        external
        auth(SET_UPSERT_FEE_ROLE)
    {
        upsertFee = _upsertFee;
    }

    /**
     * @dev Upsert a registry entry with a stake.
     * @param _scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param _sig The signature of the method the entry is describing.
     * @param _cid The IPFS CID of the file containing the Radspec description.
     */
    function stakeAndUpsertEntry(address _scope, bytes4 _sig, string _cid)
        external
        payable
    {
        require(msg.value == upsertFee, ERROR_INCORRECT_STAKE_AMOUNT);

        uint256 fee = msg.value.mul(feePct).div(PCT_BASE);
        claimableFees += fee;

        Entry storage entry_ = entries[_scope][_sig];
        entry_.stake = msg.value.sub(fee);
        entry_.cid = _cid;
        entry_.submitter = msg.sender;

        emit EntryUpserted(_scope, _sig, msg.sender, 0, _cid);
    }

    /**
     * @notice Insert or update entry for `_scope` and `_sig` with content hash `_cid`
     * @dev Upsert a registry entry without a stake.
     * @param _scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param _sig The signature of the method the entry is describing.
     * @param _cid The IPFS CID of the file containing the Radspec description.
     */
    function upsertEntry(address _scope, bytes4 _sig, string _cid)
        external
        auth(UPSERT_ENTRY_ROLE)
    {
        Entry storage entry_ = entries[_scope][_sig];
        entry_.stake = 0;
        entry_.cid = _cid;
        entry_.submitter = msg.sender;

        emit EntryUpserted(_scope, _sig, msg.sender, 0, _cid);
    }

    /**
     * @dev Get an entry from the registry.
     * @param _scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param _sig The signature of the method the entry is describing.
     * @return The CID of the entry, the submitter of the entry and the stake for the entry.
     */
    function getEntry(address _scope, bytes4 _sig)
        external
        view
        returns (string, address, uint256)
    {
        require(_hasEntry(_scope, _sig), ERROR_ENTRY_DOESNT_EXIST);
        Entry storage entry_ = entries[_scope][_sig];

        return (entry_.cid, entry_.submitter, entry_.stake);
    }

    /**
     * @dev Check whether an entry exists in the registry.
     * @param _scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param _sig The signature of the method the entry is describing.
     * @return True if the entry exists, false otherwise.
     */
    function hasEntry(address _scope, bytes4 _sig)
        external
        view
        returns (bool)
    {
        return _hasEntry(_scope, _sig);
    }

    function _hasEntry(address _scope, bytes4 _sig)
        internal
        view
        returns (bool)
    {
        Entry storage entry_ = entries[_scope][_sig];

        return entry_.submitter != address(0);
    }

    /**
     * @dev Remove an entry from the registry.
     * @param _scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param _sig The signature of the method the entry is describing.
     */
    function removeEntry(address _scope, bytes4 _sig)
        external
        auth(REMOVE_ENTRY_ROLE)
    {
        Entry storage entry_ = entries[_scope][_sig];
        claimableFees = claimableFees.add(entry_.stake);

        _removeEntry(_scope, _sig);
    }

    function _removeEntry(address _scope, bytes4 _sig) internal {
        delete entries[_scope][_sig];
        emit EntryRemoved(_scope, _sig);
    }

    /**
     * @dev Claim all fees to the beneficiary address
     */
    function claimFees()
        external
        nonReentrant
    {
        bool success = beneficiary.call.value(claimableFees)();
        require(success, ERROR_ETH_TRANSFER_FAILED);

        emit FeesClaimed(claimableFees);

        claimableFees = 0;
    }

    /**
     * @dev Dispute an entry in the registry.
     * @param _scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param _sig The signature of the method the entry is describing.
     * @return The dispute ID.
     */
    function createDispute(address _scope, bytes4 _sig)
        external
        returns (uint256)
    {
        return _createDispute(_scope, _sig);
    }

    function _createDispute(address _scope, bytes4 _sig)
        internal
        returns (uint256)
    {
        Entry storage entry = entries[_scope][_sig];
        require(_hasEntry(_scope, _sig), ERROR_ENTRY_DOESNT_EXIST);
        require(disputes[entry.disputeId].creator == address(0), ERROR_DISPUTE_EXISTS);

        (address recipient, ERC20 feeToken, uint256 disputeFees) = arbitrator.getDisputeFees();
        feeToken.approve(recipient, disputeFees);

        // First 20 bytes is the _scope, final 4 bytes is the function signature
        bytes memory metadata = abi.encodePacked(_scope, _sig);
        uint256 disputeId = arbitrator.createDispute(2, metadata);

        disputes[disputeId] = DisputeInfo(msg.sender, _scope, _sig);

        return disputeId;
    }

    /**
     * @dev Creates a dispute for an entry in the registry and submits some evidence.
     * @param _scope The scope of the entry. If the scope is the zero address, then the entry is global.
     * @param _sig The signature of the method the entry is describing.
     * @param _evidence Data submitted for the evidence of the dispute
     * @return The dispute ID.
     */
    function createDisputeAndSubmitEvidence(
        address _scope,
        bytes4 _sig,
        bytes _evidence
    )
        external
        returns (uint256)
    {
        uint256 disputeId = _createDispute(_scope, _sig);
        _submitEvidence(disputeId, _evidence, false);

        return disputeId;
    }

    /**
    * @dev Submit evidence for a dispute
    * @param _disputeId Id of the dispute in the Court
    * @param _evidence Data submitted for the evidence related to the dispute
    * @param _finished Whether or not the submitter has finished submitting evidence
    */
    function submitEvidence(uint256 _disputeId, bytes _evidence, bool _finished) external {
        _submitEvidence(_disputeId, _evidence, _finished);
    }

    function _submitEvidence(
        uint256 _disputeId,
        bytes _evidence,
        bool _finished
    )
        internal
    {
        require(_disputeExists(_disputeId), ERROR_DISPUTE_DOESNT_EXIST);
        emit EvidenceSubmitted(_disputeId, msg.sender, _evidence, _finished);

        if (_finished) {
            arbitrator.closeEvidencePeriod(_disputeId);
        }
    }

    /**
    * @dev Give a ruling for a certain dispute, the account calling it must have rights to rule on the contract
    * @param _disputeId Identification number of the dispute to be ruled
    * @param _ruling Ruling given by the arbitrator, where 0 is reserved for "refused to make a decision"
    */
    function rule(uint256 _disputeId, uint256 _ruling) external nonReentrant {
        // TODO: manage outcomes dependant on different rulings.
        require(msg.sender == address(arbitrator), ERROR_NOT_ARBITRATOR);
        require(_disputeExists(_disputeId), ERROR_DISPUTE_DOESNT_EXIST);

        DisputeInfo storage disputeInfo = disputes[_disputeId];
        Entry storage entry = entries[disputeInfo.scope][disputeInfo.sig];

        bool success = disputeInfo.creator.call.value(entry.stake)();
        require(success, ERROR_ETH_TRANSFER_FAILED);

        _removeEntry(disputeInfo.scope, disputeInfo.sig);
        delete disputes[_disputeId];

        emit Ruled(IArbitrator(msg.sender), _disputeId, _ruling);
    }

    function _disputeExists(uint256 _disputeId) view internal returns (bool) {
        return disputes[_disputeId].scope != address(0);
    }
}
