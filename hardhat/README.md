# AIJudge — Privacy-Preserving Commit-Reveal Bounty Judge

On-chain bounty system with **commit-reveal privacy** and **AI judging** via Ritual's LLM precompile (0x0802).

## Problem

Original `AIJudge.sol` had a critical flaw: `submitAnswer()` stored plaintext answers on-chain. Any participant could read others' submissions and submit an improved version.

## Solution: Commit-Reveal Flow

Answers remain hidden until after the submission deadline. Participants commit a hash, then reveal after the deadline passes.

### Lifecycle

```
Phase 1: OPEN (Commit Phase)
┌─────────────────────────────────────────────────────┐
│  Owner creates bounty with ETH reward + deadline    │
│  Participants submit commitment hashes only         │
│  commitment = keccak256(answer, salt, sender, id)   │
│  Answers stay OFF-CHAIN — only hash on-chain        │
└─────────────────────────────────────────────────────┘
                         │
                    deadline passes
                         ▼
Phase 2: COMMIT_CLOSED (Reveal Window — 1 hour)
┌─────────────────────────────────────────────────────┐
│  closeCommitPhase() transitions state               │
│  Participants reveal answer + salt                  │
│  Contract recomputes hash, verifies match           │
│  Answers now visible on-chain                       │
└─────────────────────────────────────────────────────┘
                         │
                   all reveals done
                         ▼
Phase 3: REVEALED (AI Judging)
┌─────────────────────────────────────────────────────┐
│  Owner calls judgeAll() with LLM precompile input   │
│  Ritual 0x0802 evaluates all revealed submissions   │
│  AI review stored on-chain as bytes                 │
└─────────────────────────────────────────────────────┘
                         │
                    owner reviews
                         ▼
Phase 4: JUDGED → FINALIZED
┌─────────────────────────────────────────────────────┐
│  finalizeWinner(index) pays reward to winner        │
│  ETH transferred, bounty marked complete             │
└─────────────────────────────────────────────────────┘
```

### Required Functions

| Function | Phase | Description |
|----------|-------|-------------|
| `createBounty(title, rubric, deadline)` | Open | Owner funds reward |
| `submitCommitment(bountyId, commitment)` | Open | Participant commits hash |
| `closeCommitPhase(bountyId)` | → CommitClosed | Anyone triggers after deadline |
| `revealAnswer(bountyId, answer, salt)` | CommitClosed | Participant reveals answer |
| `judgeAll(bountyId, llmInput)` | → Judged | Owner triggers AI evaluation |
| `finalizeWinner(bountyId, winnerIndex)` | → Finalized | Owner picks winner, pays reward |

### Commitment Hash Formula

```solidity
keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
```

- `answer` — the participant's submission text
- `salt` — random bytes32 chosen by participant
- `msg.sender` — prevents front-running (different hash per participant)
- `bountyId` — prevents cross-bounty replay

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        Frontend (web/)                        │
│  1. Generate random salt                                      │
│  2. Compute commitment hash locally                           │
│  3. submitCommitment() — only hash goes on-chain              │
│  4. Store (answer, salt) in localStorage                      │
│  5. After deadline: revealAnswer() with stored values         │
└───────────────────────┬──────────────────────────────────────┘
                        │
                        ▼
┌──────────────────────────────────────────────────────────────┐
│                    AIJudge.sol (on-chain)                     │
│                                                              │
│  Commitment[] ──┐                                            │
│  ├── submitter  │  Commit phase: hash only                   │
│  ├── hash       │  Reveal phase: verify + store answer       │
│  ├── revealed   │  Judge phase: batch AI evaluation          │
│  └── answer ────┘  Finalize phase: pay winner                │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Ritual LLM Precompile (0x0802)                     │    │
│  │  - Receives: all revealed answers + rubric           │    │
│  │  - Returns: AI judgment (completionData)             │    │
│  │  - TEE-backed: verifiable execution                  │    │
│  └─────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### What's Public vs Hidden

| Data | When | Visibility |
|------|------|-----------|
| Bounty metadata (title, rubric, reward) | Always | Public |
| Commitment hashes | Commit phase | Public (but meaningless without answer) |
| Participant addresses | Commit phase | Public |
| **Answers** | **Commit phase** | **HIDDEN** ← key improvement |
| Answers | Reveal phase | Public (after verification) |
| AI review | Judge phase | Public |
| Winner + payout | Finalize | Public |

## Test Plan

### Commit Phase Tests
1. ✅ Submit commitment — hash stored, answer not visible
2. ✅ Cannot submit after deadline
3. ✅ Cannot submit empty commitment
4. ✅ Cannot exceed MAX_SUBMISSIONS

### Reveal Phase Tests
5. ✅ Cannot reveal before deadline
6. ✅ Reveal with correct answer + salt — success
7. ❌ Reveal with wrong salt — reverts with "commitment mismatch"
8. ❌ Reveal with wrong answer — reverts with "commitment mismatch"
9. ❌ Double reveal — reverts with "already revealed"
10. ❌ Non-submitter reveal — reverts with "no commitment found"
11. ✅ Cannot reveal after REVEAL_WINDOW closes

### Phase Transition Tests
12. ✅ closeCommitPhase() transitions Open → CommitClosed
13. ✅ judgeAll() transitions Revealed → Judged
14. ✅ finalizeWinner() transitions Judged → Finalized
15. ❌ Cannot skip phases (e.g., judgeAll without reveals)

### Payment Tests
16. ✅ finalizeWinner() transfers reward to winner
17. ✅ Winner balance increases by reward amount
18. ❌ Cannot finalize twice

### Edge Cases
19. Single submission — reveal + judge + finalize works
20. MAX_SUBMISSIONS (10) — all reveal correctly
21. Some reveal, some don't — only revealed are judged
22. Bounty owner cannot participate (enforced off-chain or add modifier)

## Setup & Run

```bash
cd hardhat
pnpm install
pnpm hardhat compile
pnpm hardhat test test/AIJudge.test.ts
```

### Deploy to Ritual Testnet

```bash
# Set env
export DEPLOYER_PRIVATE_KEY=0x...

# Deploy
pnpm hardhat run scripts/deploy.ts --network ritual
```

## Files

```
contracts/
├── AIJudge.sol              # Commit-reveal bounty contract
└── utils/
    └── PrecompileConsumer.sol  # Ritual precompile helper

test/
└── AIJudge.test.ts          # Commit-reveal test suite

scripts/
└── deploy.ts                # Deployment script
```

## Reflection Question

> "What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?"

**Public:** Bounty metadata (title, rubric, reward, deadlines) must be public so participants can evaluate whether to compete. Commitment hashes should also be public — they prove someone committed to an answer without revealing it, enabling trustless verification later. Participant addresses and the final AI review should be public for accountability and transparency.

**Hidden:** Raw answers must remain hidden during the submission phase — this is the entire point of commit-reveal. Without privacy, fast followers can copy the best ideas and submit improved versions, destroying fairness. Salts should stay off-chain until reveal (participants store them locally). During the AI judging step, the plaintext answers exist temporarily in the LLM's execution context inside the TEE, but are never exposed to other participants or the public.

**AI vs Human Judgment:** AI excels at batch-evaluating submissions against a rubric quickly, consistently, and without favoritism — ideal for initial screening and ranking. However, AI lacks contextual understanding of intent, cultural nuance, and creative originality. The optimal pattern is hybrid: AI performs first-pass evaluation (scoring, ranking), then the human bounty owner makes the final winner selection. This is exactly what our `judgeAll()` → `finalizeWinner()` two-step flow enables — AI informs, humans decide. In high-stakes bounties, human oversight prevents AI bias from determining outcomes; in low-stakes or high-volume bounties, the AI ranking alone may suffice.
