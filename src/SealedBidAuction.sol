//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract SaledBidAuction {
    //mapping(address => bool) public userPaid;
    address public immutable beneficiary;
    uint256 public immutable commitEnd;
    uint256 public immutable revealEnd;

    uint256 public nextCommitOrder;
    bool public finalized;

    struct Bidder {
        bytes32 commitment;
        uint256 deposit;
        uint256 commitOrder;
        uint256 revealedBid;
        bool committed;
        bool revealed;
        bool settled;
    }
    mapping(address => Bidder) private bidders;
    mapping(address => uint256) public pendingWithdrawals;

    address public highestBidder;
    uint256 public highestBid;

    error ZeroAddress();
    error InvalidDuration();
    error CommitPhaseClosed();
    error InvalidCommitment();
    error AlreadyCommitted();
    error InvalidBid();
    error BidExceedsDeposit();
    error ZeroDeposit();
    error InvalidReveal();
    error RevealPhaseNotOpen();
    error RevealPhaseClosed();
    error NoCommitment();
    error AlreadyRevealed();
    error AlreadyFinalized();
    error NotFinalized();
    error AlreadySettled();
    error AuctionNotEnded();
    error NothingToWithdraw();
    error TransferFailed();
    

    event BidCommitted(address indexed bidder);
    event BidRevealed(address indexed bidder, uint256 bid);
    event AuctionFinalized(address indexed winner, uint256 winningBid);
    event BidSettled(address indexed bidder, uint256 refund, uint256 proceeds);
    event Withdrawal(address indexed account, uint256 amount);

    constructor(address _beneficiary, uint256 commitDuration, uint256 revealDuration) {
        if (_beneficiary == address(0)) revert ZeroAddress();
        if (commitDuration == 0 || revealDuration == 0) {
            revert InvalidDuration();
        }

        beneficiary = _beneficiary;
        commitEnd = block.timestamp + commitDuration;
        revealEnd = commitEnd + revealDuration;
    }

    function makeCommitment(uint256 bid, bytes32 secret) external view returns(bytes32) {
        return keccak256(
            abi.encode(
                bid,
                secret,
                msg.sender,
                address(this),
                block.chainid
            )
        );
    }

    function commitBid(bytes32 _commitment) external payable {
        if (block.timestamp >= commitEnd) revert CommitPhaseClosed();
        if (_commitment == bytes32(0)) revert InvalidCommitment();
        if (bidders[msg.sender].committed) revert AlreadyCommitted();
        if (msg.value == 0) revert ZeroDeposit();

        bidders[msg.sender] = Bidder({
            commitment: _commitment,
            deposit: msg.value,
            commitOrder: nextCommitOrder++,
            revealedBid: 0,
            committed: true,
            revealed: false,
            settled: false
        });
        emit BidCommitted(msg.sender);
    }

    function revealBid(uint256 bid, bytes32 secret) external {
        if (block.timestamp < commitEnd) revert RevealPhaseNotOpen();
        if (block.timestamp >= revealEnd) revert RevealPhaseClosed();

        Bidder storage b = bidders[msg.sender];
        if (!b.committed) revert NoCommitment();
        if (b.revealed) revert AlreadyRevealed();
        if (bid == 0) revert InvalidBid();
        if (bid > b.deposit) revert BidExceedsDeposit();

        bytes32 expected = keccak256(abi.encode(
            bid,
            secret,
            msg.sender,
            address(this),
            block.chainid
        ));

        if (expected != b.commitment) revert  InvalidReveal();
        b.revealed = true;
        b.revealedBid = bid;

        bool isBetter =
            bid > highestBid ||
            (
                bid == highestBid &&
                (
                    highestBidder == address(0) ||
                    b.commitOrder <
                    bidders[highestBidder].commitOrder
                )
            );
        if (isBetter) {
            highestBid = bid;
            highestBidder = msg.sender;
        }
        emit BidRevealed(msg.sender, bid);
    }

    function finalize() external {
        if (block.timestamp < revealEnd) {
            revert AuctionNotEnded();
        }
        if (finalized) revert AlreadyFinalized();
        finalized = true;
        emit AuctionFinalized(highestBidder, highestBid);
    }

    function settleBid(address bidder) external {
        if (!finalized) revert NotFinalized();

        Bidder storage b = bidders[bidder];

        if (!b.committed) revert NoCommitment();
        if (b.settled) revert AlreadySettled();

        b.settled = true;
        uint256 refund;
        uint256 proceeds;

        if(!b.revealed) {
            proceeds = b.deposit;
        } else if (bidder == highestBidder) {
            proceeds = b.revealedBid;
            refund = b.deposit - b.revealedBid;
        } else {
            refund = b.deposit;
        }

        b.deposit = 0;

        if (refund > 0) pendingWithdrawals[bidder] += refund;
        if (proceeds > 0) pendingWithdrawals[beneficiary] += proceeds;

        emit BidSettled(bidder, refund, proceeds);
    }

    function withdraw() external {
        if (!finalized) revert NotFinalized();

        uint256 amount = pendingWithdrawals[msg.sender];

        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawal(msg.sender, amount);
    }

    function getBidder(address bidder) external view returns (
            uint256 deposit,
            uint256 commitOrder,
            uint256 revealedBid,
            bool committed,
            bool revealed,
            bool settled
        )
    {
        Bidder storage b = bidders[bidder];
        return (
            b.deposit,
            b.commitOrder,
            b.revealedBid,
            b.committed,
            b.revealed,
            b.settled
        );
    }
}