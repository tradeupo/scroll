// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { IZKRollup } from "./IZKRollup.sol";
import { RollupVerifier } from "../../libraries/verifier/RollupVerifier.sol";

// solhint-disable reason-string

/// @title ZKRollup
/// @notice This contract maintains essential data for zk rollup, including:
///
/// 1. a list of pending messages, which will be relayed to layer 2;
/// 2. the block tree generated by layer 2 and it's status.
///
/// @dev the message queue is not used yet, the offline relayer only use events in `L1ScrollMessenger`.
contract ZKRollup is OwnableUpgradeable, IZKRollup {
  /**************************************** Events ****************************************/

  /// @notice Emitted when owner updates address of operator
  /// @param _oldOperator The address of old operator.
  /// @param _newOperator The address of new operator.
  event UpdateOperator(address _oldOperator, address _newOperator);

  /// @notice Emitted when owner updates address of messenger
  /// @param _oldMesssenger The address of old messenger contract.
  /// @param _newMesssenger The address of new messenger contract.
  event UpdateMesssenger(address _oldMesssenger, address _newMesssenger);

  /**************************************** Variables ****************************************/

  struct Layer2BlockStored {
    bytes32 parentHash;
    bytes32 transactionRoot;
    uint64 blockHeight;
    uint64 batchIndex;
  }

  struct Layer2BatchStored {
    bytes32 batchHash;
    bytes32 parentHash;
    uint64 batchIndex;
    bool verified;
  }

  /// @notice The chain id of the corresponding layer 2 chain.
  uint256 public layer2ChainId;

  /// @notice The address of L1ScrollMessenger.
  address public messenger;

  /// @notice The address of operator.
  address public operator;

  /// @dev The index of the first queue element not yet executed.
  /// The operator should change this variable when new block is commited.
  uint256 private nextQueueIndex;

  /// @dev The list of appended message hash.
  bytes32[] private messageQueue;

  /// @notice The latest finalized batch id.
  bytes32 public lastFinalizedBatchID;

  /// @notice Mapping from block hash to block struct.
  mapping(bytes32 => Layer2BlockStored) public blocks;

  /// @notice Mapping from batch id to batch struct.
  mapping(bytes32 => Layer2BatchStored) public batches;

  /// @notice Mapping from batch index to finalized batch id.
  mapping(uint256 => bytes32) public finalizedBatches;

  modifier OnlyOperator() {
    // @todo In the decentralize mode, it should be only called by a list of validator.
    require(msg.sender == operator, "caller not operator");
    _;
  }

  /**************************************** Constructor ****************************************/

  function initialize(uint256 _chainId) public initializer {
    OwnableUpgradeable.__Ownable_init();

    layer2ChainId = _chainId;
  }

  /**************************************** View Functions ****************************************/

  /// @inheritdoc IZKRollup
  function getMessageHashByIndex(uint256 _index) external view returns (bytes32) {
    return messageQueue[_index];
  }

  /// @inheritdoc IZKRollup
  function getNextQueueIndex() external view returns (uint256) {
    return nextQueueIndex;
  }

  /// @notice Return the total number of appended message.
  function getQeueuLength() external view returns (uint256) {
    return messageQueue.length;
  }

  /// @inheritdoc IZKRollup
  function layer2GasLimit(uint256) public view virtual returns (uint256) {
    // hardcode for now
    return 30000000;
  }

  /// @inheritdoc IZKRollup
  function verifyMessageStateProof(uint256 _batchIndex, uint256 _blockHeight) external view returns (bool) {
    bytes32 _batchId = finalizedBatches[_batchIndex];
    // check if batch is verified
    if (_batchId == bytes32(0)) return false;

    uint256 _maxBlockHeightInBatch = blocks[batches[_batchId].batchHash].blockHeight;
    // check block height is in batch range.
    if (_maxBlockHeightInBatch == 0) return _blockHeight == 0;
    else {
      uint256 _minBlockHeightInBatch = blocks[batches[_batchId].parentHash].blockHeight + 1;
      return _minBlockHeightInBatch <= _blockHeight && _blockHeight <= _maxBlockHeightInBatch;
    }
  }

  /**************************************** Mutated Functions ****************************************/

  /// @inheritdoc IZKRollup
  function appendMessage(
    address _sender,
    address _target,
    uint256 _value,
    uint256 _fee,
    uint256 _deadline,
    bytes memory _message,
    uint256 _gasLimit
  ) external override returns (uint256) {
    // currently make only messenger to call
    require(msg.sender == messenger, "caller not messenger");
    uint256 _nonce = messageQueue.length;

    // @todo may change it later
    bytes32 _messageHash = keccak256(
      abi.encodePacked(_sender, _target, _value, _fee, _deadline, _nonce, _message, _gasLimit)
    );
    messageQueue.push(_messageHash);

    return _nonce;
  }

  /// @notice Import layer 2 genesis block
  function importGenesisBlock(Layer2BlockHeader memory _genesis) external onlyOwner {
    require(lastFinalizedBatchID == bytes32(0), "Genesis block imported");
    require(_genesis.blockHash != bytes32(0), "Block hash is zero");
    require(_genesis.blockHeight == 0, "Block is not genesis");
    require(_genesis.parentHash == bytes32(0), "Parent hash not empty");

    require(_verifyBlockHash(_genesis), "Block hash verification failed");

    Layer2BlockStored storage _block = blocks[_genesis.blockHash];
    _block.transactionRoot = _computeTransactionRoot(_genesis.txs);

    bytes32 _batchId = _computeBatchId(_genesis.blockHash, bytes32(0), 0);
    Layer2BatchStored storage _batch = batches[_batchId];

    _batch.batchHash = _genesis.blockHash;
    _batch.verified = true;

    lastFinalizedBatchID = _batchId;
    finalizedBatches[0] = _batchId;

    emit CommitBatch(_batchId, _genesis.blockHash, 0, bytes32(0));
    emit FinalizeBatch(_batchId, _genesis.blockHash, 0, bytes32(0));
  }

  /// @inheritdoc IZKRollup
  function commitBatch(Layer2Batch memory _batch) external override OnlyOperator {
    // check whether the batch is empty
    require(_batch.blocks.length > 0, "Batch is empty");

    bytes32 _batchHash = _batch.blocks[_batch.blocks.length - 1].blockHash;
    bytes32 _batchId = _computeBatchId(_batchHash, _batch.parentHash, _batch.batchIndex);
    Layer2BatchStored storage _batchStored = batches[_batchId];

    // check whether the batch is commited before
    require(_batchStored.batchHash == bytes32(0), "Batch has been committed before");

    // make sure the parent batch is commited before
    Layer2BlockStored storage _parentBlock = blocks[_batch.parentHash];
    require(_parentBlock.transactionRoot != bytes32(0), "Parent batch hasn't been committed");
    require(_parentBlock.batchIndex + 1 == _batch.batchIndex, "Batch index and parent batch index mismatch");

    // check whether the blocks are correct.
    unchecked {
      uint256 _expectedBlockHeight = _parentBlock.blockHeight + 1;
      bytes32 _expectedParentHash = _batch.parentHash;
      for (uint256 i = 0; i < _batch.blocks.length; i++) {
        Layer2BlockHeader memory _block = _batch.blocks[i];
        require(_verifyBlockHash(_block), "Block hash verification failed");
        require(_block.parentHash == _expectedParentHash, "Block parent hash mismatch");
        require(_block.blockHeight == _expectedBlockHeight, "Block height mismatch");
        require(blocks[_block.blockHash].transactionRoot == bytes32(0), "Block has been commited before");

        _expectedBlockHeight += 1;
        _expectedParentHash = _block.blockHash;
      }
    }

    // do block commit
    for (uint256 i = 0; i < _batch.blocks.length; i++) {
      Layer2BlockHeader memory _block = _batch.blocks[i];
      Layer2BlockStored storage _blockStored = blocks[_block.blockHash];
      _blockStored.parentHash = _block.parentHash;
      _blockStored.transactionRoot = _computeTransactionRoot(_block.txs);
      _blockStored.blockHeight = _block.blockHeight;
      _blockStored.batchIndex = _batch.batchIndex;
    }

    _batchStored.batchHash = _batchHash;
    _batchStored.parentHash = _batch.parentHash;
    _batchStored.batchIndex = _batch.batchIndex;

    emit CommitBatch(_batchId, _batchHash, _batch.batchIndex, _batch.parentHash);
  }

  /// @inheritdoc IZKRollup
  function revertBatch(bytes32 _batchId) external override OnlyOperator {
    Layer2BatchStored storage _batch = batches[_batchId];

    require(_batch.batchHash != bytes32(0), "No such batch");
    require(!_batch.verified, "Unable to revert verified batch");

    bytes32 _blockHash = _batch.batchHash;
    bytes32 _parentHash = _batch.parentHash;

    // delete commited blocks
    while (_blockHash != _parentHash) {
      bytes32 _nextBlockHash = blocks[_blockHash].parentHash;
      delete blocks[_blockHash];

      _blockHash = _nextBlockHash;
    }

    // delete commited batch
    delete batches[_batchId];

    emit RevertBatch(_batchId);
  }

  /// @inheritdoc IZKRollup
  function finalizeBatchWithProof(
    bytes32 _batchId,
    uint256[] memory _proof,
    uint256[] memory _instances
  ) external override OnlyOperator {
    Layer2BatchStored storage _batch = batches[_batchId];
    require(_batch.batchHash != bytes32(0), "No such batch");
    require(!_batch.verified, "Batch already verified");

    // @note skip parent check for now, since we may not prove blocks in order.
    // bytes32 _parentHash = _block.header.parentHash;
    // require(lastFinalizedBlockHash == _parentHash, "parent not latest finalized");
    // this check below is not needed, just incase
    // require(blocks[_parentHash].verified, "parent not verified");

    // @todo add verification logic
    RollupVerifier.verify(_proof, _instances);

    uint256 _batchIndex = _batch.batchIndex;
    finalizedBatches[_batchIndex] = _batchId;
    _batch.verified = true;

    Layer2BatchStored storage _finalizedBatch = batches[lastFinalizedBatchID];
    if (_batchIndex > _finalizedBatch.batchIndex) {
      lastFinalizedBatchID = _batchId;
    }

    emit FinalizeBatch(_batchId, _batch.batchHash, _batchIndex, _batch.parentHash);
  }

  /**************************************** Restricted Functions ****************************************/

  /// @notice Update the address of operator.
  /// @dev This function can only called by contract owner.
  /// @param _newOperator The new operator address to update.
  function updateOperator(address _newOperator) external onlyOwner {
    address _oldOperator = operator;
    require(_oldOperator != _newOperator, "change to same operator");

    operator = _newOperator;

    emit UpdateOperator(_oldOperator, _newOperator);
  }

  /// @notice Update the address of messenger.
  /// @dev This function can only called by contract owner.
  /// @param _newMessenger The new messenger address to update.
  function updateMessenger(address _newMessenger) external onlyOwner {
    address _oldMessenger = messenger;
    require(_oldMessenger != _newMessenger, "change to same messenger");

    messenger = _newMessenger;

    emit UpdateMesssenger(_oldMessenger, _newMessenger);
  }

  /**************************************** Internal Functions ****************************************/

  function _verifyBlockHash(Layer2BlockHeader memory) internal pure returns (bool) {
    // @todo finish logic after more discussions
    return true;
  }

  /// @dev Internal function to compute a unique batch id for mapping.
  /// @param _batchHash The hash of the batch.
  /// @param _parentHash The hash of the batch.
  /// @param _batchIndex The index of the batch.
  /// @return Return the computed batch id.
  function _computeBatchId(
    bytes32 _batchHash,
    bytes32 _parentHash,
    uint256 _batchIndex
  ) internal pure returns (bytes32) {
    return keccak256(abi.encode(_batchHash, _parentHash, _batchIndex));
  }

  /// @dev Internal function to compute transaction root.
  /// @param _txn The list of transactions in the block.
  /// @return Return the hash of transaction root.
  function _computeTransactionRoot(Layer2Transaction[] memory _txn) internal pure returns (bytes32) {
    bytes32[] memory _hashes = new bytes32[](_txn.length);
    for (uint256 i = 0; i < _txn.length; i++) {
      // @todo use rlp
      _hashes[i] = keccak256(
        abi.encode(
          _txn[i].caller,
          _txn[i].nonce,
          _txn[i].target,
          _txn[i].gas,
          _txn[i].gasPrice,
          _txn[i].value,
          _txn[i].data,
          _txn[i].r,
          _txn[i].s,
          _txn[i].v
        )
      );
    }
    return keccak256(abi.encode(_hashes));
  }
}