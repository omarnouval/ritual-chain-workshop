// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

/**
 * @title AIJudge — Privacy-Preserving Bounty Judge
 * @notice Commit-reveal flow: participants submit commitment hashes during the
 *         submission phase, then reveal their answers after the deadline. Only
 *         valid, revealed answers are eligible for on-chain AI judging via
 *         Ritual's LLM precompile (0x0802).
 *
 * Lifecycle:
 *   1. createBounty          — owner funds reward + sets deadline
 *   2. submitCommitment      — participants commit hash (hidden)
 *   3. [deadline passes]
 *   4. revealAnswer          — participants reveal answer + salt
 *   5. judgeAll              — owner triggers batch AI judging (all revealed)
 *   6. finalizeWinner        — owner picks winner, reward is paid out
 */
contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;
    uint256 public constant REVEAL_WINDOW = 1 hours;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    enum BountyPhase { Open, CommitClosed, Revealed, Judged, Finalized }

    struct Commitment {
        address submitter;
        bytes32 hash;
        bool revealed;
        string answer; // empty until revealed
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 deadline;       // submission (commit) deadline
        uint256 revealDeadline; // deadline + REVEAL_WINDOW
        BountyPhase phase;
        bytes aiReview;
        uint256 winnerIndex;
        Commitment[] commitments;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    // ── Events ──────────────────────────────────────────────────────────────

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 deadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed index,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed index,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // ── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // ── 1. Create Bounty ────────────────────────────────────────────────────

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 deadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(deadline > block.timestamp, "deadline must be future");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.deadline = deadline;
        bounty.revealDeadline = deadline + REVEAL_WINDOW;
        bounty.phase = BountyPhase.Open;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, deadline);
    }

    // ── 2. Submit Commitment (hidden) ───────────────────────────────────────

    /**
     * @notice Submit a commitment hash during the submission phase.
     * @dev    commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *         Only the hash is stored on-chain — answer stays hidden.
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.phase == BountyPhase.Open, "not accepting commits");
        require(block.timestamp < bounty.deadline, "commit phase ended");
        require(
            bounty.commitments.length < MAX_SUBMISSIONS,
            "too many submissions"
        );
        require(commitment != bytes32(0), "empty commitment");

        uint256 index = bounty.commitments.length;
        bounty.commitments.push(
            Commitment({
                submitter: msg.sender,
                hash: commitment,
                revealed: false,
                answer: ""
            })
        );

        emit CommitmentSubmitted(bountyId, index, msg.sender, commitment);
    }

    // ── 3. Close Commit Phase ───────────────────────────────────────────────

    /**
     * @notice Transition from Open → CommitClosed after the deadline.
     *         Anyone can call this — it's a pure state transition.
     */
    function closeCommitPhase(
        uint256 bountyId
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        require(bounty.phase == BountyPhase.Open, "not in open phase");
        require(block.timestamp >= bounty.deadline, "deadline not reached");

        bounty.phase = BountyPhase.CommitClosed;
    }

    // ── 4. Reveal Answer ────────────────────────────────────────────────────

    /**
     * @notice Reveal your answer after the commit deadline.
     * @dev    Contract recomputes keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *         and checks it matches the stored commitment.
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            bounty.phase == BountyPhase.CommitClosed ||
            bounty.phase == BountyPhase.Revealed,
            "cannot reveal now"
        );
        require(block.timestamp < bounty.revealDeadline, "reveal window closed");
        require(bytes(answer).length > 0, "empty answer");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        // Find the caller's commitment (revealed or not)
        uint256 idx = _findCommitment(bountyId, msg.sender, false);
        require(idx != type(uint256).max, "no commitment found");
        require(!bounty.commitments[idx].revealed, "already revealed");

        // Verify the commitment hash
        bytes32 computed = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(
            computed == bounty.commitments[idx].hash,
            "commitment mismatch"
        );

        bounty.commitments[idx].revealed = true;
        bounty.commitments[idx].answer = answer;
        bounty.phase = BountyPhase.Revealed;

        emit AnswerRevealed(bountyId, idx, msg.sender);
    }

    // ── 5. Judge All (AI) ───────────────────────────────────────────────────

    /**
     * @notice Owner triggers AI judging on all revealed submissions.
     * @dev    Uses Ritual's LLM precompile (0x0802) for batch evaluation.
     *         llmInput is the ABI-encoded precompile calldata containing the
     *         judge prompt with all revealed answers.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            bounty.phase == BountyPhase.Revealed,
            "not all answers revealed"
        );
        require(_countRevealed(bountyId) > 0, "no revealed answers");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,
        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.phase = BountyPhase.Judged;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    // ── 6. Finalize Winner ──────────────────────────────────────────────────

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.phase == BountyPhase.Judged, "not judged yet");
        require(
            winnerIndex < bounty.commitments.length,
            "invalid winner index"
        );
        require(
            bounty.commitments[winnerIndex].revealed,
            "winner did not reveal"
        );

        bounty.phase = BountyPhase.Finalized;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.commitments[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ── View Functions ──────────────────────────────────────────────────────

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 deadline,
            uint256 revealDeadline,
            uint8 phase,
            uint256 commitmentCount,
            uint256 winnerIndex
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.deadline,
            bounty.revealDeadline,
            uint8(bounty.phase),
            bounty.commitments.length,
            bounty.winnerIndex
        );
    }

    function getAiReview(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (bytes memory) {
        return bounties[bountyId].aiReview;
    }

    function getRevealedCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return _countRevealed(bountyId);
    }

    function getCommitment(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 hash,
            bool revealed,
            string memory answer
        )
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.commitments.length, "invalid index");

        Commitment storage c = bounty.commitments[index];
        return (c.submitter, c.hash, c.revealed, c.answer);
    }

    function getRevealedSubmissions(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (address[] memory submitters, string[] memory answers)
    {
        Bounty storage bounty = bounties[bountyId];
        uint256 count = _countRevealed(bountyId);

        submitters = new address[](count);
        answers = new string[](count);

        uint256 j = 0;
        for (uint256 i = 0; i < bounty.commitments.length; i++) {
            if (bounty.commitments[i].revealed) {
                submitters[j] = bounty.commitments[i].submitter;
                answers[j] = bounty.commitments[i].answer;
                j++;
            }
        }
    }

    // ── Internal ────────────────────────────────────────────────────────────

    function _findCommitment(
        uint256 bountyId,
        address submitter,
        bool unrevealedOnly
    ) internal view returns (uint256) {
        Bounty storage bounty = bounties[bountyId];
        for (uint256 i = 0; i < bounty.commitments.length; i++) {
            if (bounty.commitments[i].submitter == submitter) {
                if (!unrevealedOnly || !bounty.commitments[i].revealed) {
                    return i;
                }
            }
        }
        return type(uint256).max;
    }

    function _countRevealed(
        uint256 bountyId
    ) internal view returns (uint256) {
        Bounty storage bounty = bounties[bountyId];
        uint256 count = 0;
        for (uint256 i = 0; i < bounty.commitments.length; i++) {
            if (bounty.commitments[i].revealed) count++;
        }
        return count;
    }
}
