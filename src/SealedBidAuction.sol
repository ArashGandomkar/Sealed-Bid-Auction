//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


contract SealedBidAuction is Ownable, ReentrancyGuard, Pausable {
    uint256 public constant MIN_DURATION = 12 hours;
    uint256 public _auctionId = 1;

    struct Auction {
        address beneficiary;
        uint256 commitEnd;
        uint256 revealEnd;
        uint256 nextCommitOrder;
        address highestBidder;
        uint256 highestBid;
        bool finalized;
        bool exists;
        bool cancelled;
        uint256 reservePrice;
    }
    mapping (uint256 => Auction) public auctions;
    

    struct Bidder {
        bytes32 commitment;
        uint256 deposit;
        uint256 commitOrder;
        uint256 revealedBid;
        bool committed;
        bool revealed;
        bool settled;
        bool bidRevised;
    }
    
    mapping (uint256 => mapping (address => Bidder)) private bidders;
    mapping (uint256 => mapping (address => uint256)) public pendingWithdrawals;

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
    error AuctionNotFound();
    error AuctionAlreadyCancelled();
    error AuctionHasBids();
    error CancellationClosed();
    error BidBelowReservePrice();
    error BidAlreadyRevised();
    error DepositBelowReservePrice();

    event BidCommitted(address indexed bidder, uint256 indexed auctionId);
    event BidRevealed(address indexed bidder,uint256 indexed auctionId, uint256 bid);
    event AuctionFinalized(address indexed winner, uint256 indexed auctionId, uint256 winningBid);
    event BidSettled(address indexed bidder, uint256 indexed auctionId, uint256 refund, uint256 proceeds);
    event Withdrawal(address indexed account, uint256 indexed auctionId, uint256 amount);
    event AuctionCreated(uint256 indexed auctionId, address indexed beneficiary, uint256 commitEnd, uint256 revealEnd);
    event AuctionCancelled(uint256 indexed auctionId);
    event BidRevised(address indexed bidder, uint256 indexed auctionId);

    constructor() Ownable(msg.sender) {}

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    function makeCommitment(uint256 bid, bytes32 secret, uint256 auctionId) external view returns(bytes32) {
        if (!auctions[auctionId].exists) revert AuctionNotFound();
        if (bid < auctions[auctionId].reservePrice) revert BidBelowReservePrice();
        return keccak256(
            abi.encode(
                auctionId,
                bid,
                secret,
                msg.sender,
                address(this),
                block.chainid
            )
        );
    }

    function commitBid(bytes32 _commitment, uint256 auctionId) external payable whenNotPaused {
        if (!auctions[auctionId].exists) revert AuctionNotFound();
        if (auctions[auctionId].cancelled) revert AuctionAlreadyCancelled();
        if (block.timestamp >= auctions[auctionId].commitEnd) revert CommitPhaseClosed();
        if (_commitment == bytes32(0)) revert InvalidCommitment();
        if (bidders[auctionId][msg.sender].committed) revert AlreadyCommitted();
        if (msg.value == 0) revert ZeroDeposit();

        bidders[auctionId][msg.sender] = Bidder({
            commitment: _commitment,
            deposit: msg.value,
            commitOrder: auctions[auctionId].nextCommitOrder++,
            revealedBid: 0,
            committed: true,
            revealed: false,
            settled: false,
            bidRevised: false
        });
        emit BidCommitted(msg.sender, auctionId);
    }

    function revealBid(uint256 bid, bytes32 secret, uint256 auctionId) external {
        if (!auctions[auctionId].exists) revert AuctionNotFound();
        if (auctions[auctionId].cancelled) revert AuctionAlreadyCancelled();
        if (block.timestamp < auctions[auctionId].commitEnd) revert RevealPhaseNotOpen();
        if (block.timestamp >= auctions[auctionId].revealEnd) revert RevealPhaseClosed();
        if (bid < auctions[auctionId].reservePrice) revert BidBelowReservePrice();

        Bidder storage b = bidders[auctionId][msg.sender];
        if (!b.committed) revert NoCommitment();
        if (b.revealed) revert AlreadyRevealed();
        if (bid == 0) revert InvalidBid();
        if (bid > b.deposit) revert BidExceedsDeposit();

        bytes32 expected = keccak256(abi.encode(
            auctionId,
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
            bid > auctions[auctionId].highestBid ||
            (
                bid == auctions[auctionId].highestBid &&
                (
                    auctions[auctionId].highestBidder == address(0) ||
                    b.commitOrder <
                    bidders[auctionId][auctions[auctionId].highestBidder].commitOrder
                )
            );
        if (isBetter) {
            auctions[auctionId].highestBid = bid;
            auctions[auctionId].highestBidder = msg.sender;
        }
        emit BidRevealed(msg.sender, auctionId, bid);
    }

    function finalize(uint auctionId) external {
        if (!auctions[auctionId].exists) revert AuctionNotFound();
        if (auctions[auctionId].cancelled) revert AuctionAlreadyCancelled();
        if (block.timestamp < auctions[auctionId].revealEnd) {
            revert AuctionNotEnded();
        }
        if (auctions[auctionId].finalized) revert AlreadyFinalized();
        auctions[auctionId].finalized = true;
        emit AuctionFinalized(auctions[auctionId].highestBidder, auctionId, auctions[auctionId].highestBid);
    }

    function settleBid(address bidder, uint256 auctionId) external {
        if (!auctions[auctionId].exists) revert AuctionNotFound();
        if (auctions[auctionId].cancelled) revert AuctionAlreadyCancelled();
        if (!auctions[auctionId].finalized) revert NotFinalized();

        Bidder storage b = bidders[auctionId][bidder];

        if (!b.committed) revert NoCommitment();
        if (b.settled) revert AlreadySettled();

        b.settled = true;
        uint256 refund;
        uint256 proceeds;

        if(!b.revealed) {
            proceeds = b.deposit / 10;
            refund = b.deposit - proceeds;
        } else if (bidder == auctions[auctionId].highestBidder) {
            proceeds = b.revealedBid;
            refund = b.deposit - b.revealedBid;
        } else {
            refund = b.deposit;
        }

        b.deposit = 0;

        if (refund > 0) pendingWithdrawals[auctionId][bidder] += refund;
        if (proceeds > 0) pendingWithdrawals[auctionId][auctions[auctionId].beneficiary] += proceeds;

        emit BidSettled(bidder, auctionId, refund, proceeds);
    }

    function withdraw(uint256 auctionId) external nonReentrant {
        if (!auctions[auctionId].exists) revert AuctionNotFound();
        if (!auctions[auctionId].finalized) revert NotFinalized();

        uint256 amount = pendingWithdrawals[auctionId][msg.sender];

        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[auctionId][msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawal(msg.sender, auctionId, amount);
    }

    function getBidder(uint256 auctionId, address bidder) external view returns (
            uint256 deposit,
            uint256 commitOrder,
            uint256 revealedBid,
            bool committed,
            bool revealed,
            bool settled,
            bool bidRevised
        )
    {
        if (!auctions[auctionId].exists) revert AuctionNotFound();
        Bidder storage b = bidders[auctionId][bidder];
        return (
            b.deposit,
            b.commitOrder,
            b.revealedBid,
            b.committed,
            b.revealed,
            b.settled,
            b.bidRevised
        );
    }

    function createAuction(address _beneficiary, uint256 commitDuration, uint256 revealDuration, uint256 _reservePrice) external onlyOwner whenNotPaused returns(uint256 auctionId) {
        if (_beneficiary == address(0)) revert ZeroAddress();
        if (commitDuration == 0 || revealDuration == 0) {
            revert InvalidDuration();
        }
        if (revealDuration < MIN_DURATION || commitDuration < MIN_DURATION) {
            revert InvalidDuration();
        }
        auctionId = _auctionId;
        uint256 _commitEnd = block.timestamp + commitDuration;
        uint256 _revealEnd = _commitEnd + revealDuration;
        auctions[_auctionId] = Auction({
            beneficiary : _beneficiary,
            commitEnd : _commitEnd,
            revealEnd : _revealEnd,
            nextCommitOrder : 0,
            highestBidder : address(0),
            highestBid: 0,
            finalized : false,
            exists : true,
            cancelled : false,
            reservePrice : _reservePrice
        });
        _auctionId++;
        emit AuctionCreated(auctionId, _beneficiary, _commitEnd, _revealEnd);
    }

    function cancelAuction(uint256 auctionId) external onlyOwner {
        Auction storage auction = auctions[auctionId];

        if (!auction.exists) revert AuctionNotFound();
        if (auction.cancelled) revert AuctionAlreadyCancelled();
        if (block.timestamp >= auction.commitEnd) revert CancellationClosed();
        if (auction.nextCommitOrder > 0) revert AuctionHasBids();

        auction.cancelled = true;
        emit AuctionCancelled(auctionId);
    }

    function reviseBid(
        uint256 auctionId,
        bytes32 newCommitment
    ) external payable whenNotPaused nonReentrant {
        Auction storage auction = auctions[auctionId];
        Bidder storage b = bidders[auctionId][msg.sender];
        if (!auction.exists) revert AuctionNotFound();
        if (auction.cancelled) revert AuctionAlreadyCancelled();
        if (block.timestamp >= auction.commitEnd) revert CommitPhaseClosed();
        if (!b.committed) revert NoCommitment();
        if (b.bidRevised) revert BidAlreadyRevised();
        if (newCommitment == bytes32(0)) revert InvalidCommitment();
        if (newCommitment == b.commitment) revert InvalidCommitment();

        uint256 newDeposit = b.deposit + msg.value;
        if (newDeposit < auction.reservePrice) revert DepositBelowReservePrice();

        b.commitment = newCommitment;
        b.deposit = newDeposit;
        b.bidRevised = true;

        emit BidRevised(msg.sender, auctionId);
    }
}