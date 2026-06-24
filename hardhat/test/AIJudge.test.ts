import { describe, it } from "node:test";
import hre from "hardhat";
import { parseEther, keccak256, toBytes, encodePacked } from "viem";

const { viem, networkHelpers } = await hre.network.create();

function computeCommitment(
  answer: string,
  salt: `0x${string}`,
  submitter: `0x${string}`,
  bountyId: bigint
): `0x${string}` {
  return keccak256(
    encodePacked(
      ["string", "bytes32", "address", "uint256"],
      [answer, salt, submitter, bountyId]
    )
  );
}

async function futureDeadline(secondsFromNow: number): Promise<bigint> {
  const publicClient = await viem.getPublicClient();
  const block = await publicClient.getBlock();
  return block.timestamp + BigInt(secondsFromNow);
}

describe("AIJudge — Commit-Reveal Bounty", function () {
  it("full lifecycle: commit → reveal → verify hidden until reveal", async function () {
    const [owner, alice, bob] = await viem.getWalletClients();

    const aiJudge = await viem.deployContract("AIJudge");
    const deadline = await futureDeadline(3600);
    const bountyId = 1n;
    const salt1 = keccak256(toBytes("salt-alice-1"));
    const salt2 = keccak256(toBytes("salt-bob-2"));
    const answer1 = "Alice's brilliant answer";
    const answer2 = "Bob's even better answer";

    // 1. Create bounty
    await aiJudge.write.createBounty(
      ["Test Bounty", "Best answer wins", deadline],
      { account: owner.account, value: parseEther("1.0") }
    );

    // 2. Submit commitments (hidden)
    const commit1 = computeCommitment(answer1, salt1, alice.account.address, bountyId);
    await aiJudge.write.submitCommitment([bountyId, commit1], {
      account: alice.account,
    });

    const commit2 = computeCommitment(answer2, salt2, bob.account.address, bountyId);
    await aiJudge.write.submitCommitment([bountyId, commit2], {
      account: bob.account,
    });

    // Verify: answers hidden during commit phase
    const c1 = await aiJudge.read.getCommitment([bountyId, 0n]);
    console.log("Commitment before reveal:", { revealed: c1[2], answer: c1[3] });
    if (c1[2] !== false) throw new Error("should not be revealed");
    if (c1[3] !== "") throw new Error("answer should be empty (hidden)");

    // 3. Fast-forward past deadline
    await networkHelpers.time.increase(3601);

    // 4. Close commit phase
    await aiJudge.write.closeCommitPhase([bountyId], {
      account: owner.account,
    });

    // 5. Reveal answers
    await aiJudge.write.revealAnswer([bountyId, answer1, salt1], {
      account: alice.account,
    });

    await aiJudge.write.revealAnswer([bountyId, answer2, salt2], {
      account: bob.account,
    });

    // Verify: answers now visible
    const c1After = await aiJudge.read.getCommitment([bountyId, 0n]);
    console.log("Commitment after reveal:", { revealed: c1After[2], answer: c1After[3] });
    if (c1After[2] !== true) throw new Error("should be revealed");
    if (c1After[3] !== answer1) throw new Error("answer should match");

    // 6. Get all revealed submissions
    const revealed = await aiJudge.read.getRevealedSubmissions([bountyId]);
    console.log("Revealed submissions:", revealed[0].length);
    if (revealed[0].length !== 2) throw new Error("should have 2 revealed");
  });

  it("reject reveal with wrong salt", async function () {
    const [owner, alice] = await viem.getWalletClients();

    const aiJudge = await viem.deployContract("AIJudge");
    const deadline = await futureDeadline(100);
    const bountyId = 1n;
    const salt = keccak256(toBytes("real-salt"));
    const wrongSalt = keccak256(toBytes("wrong-salt"));
    const answer = "my answer";

    await aiJudge.write.createBounty(["Test", "Rubric", deadline], {
      account: owner.account,
      value: parseEther("0.5"),
    });

    const commitment = computeCommitment(answer, salt, alice.account.address, bountyId);
    await aiJudge.write.submitCommitment([bountyId, commitment], {
      account: alice.account,
    });

    await networkHelpers.time.increase(101);
    await aiJudge.write.closeCommitPhase([bountyId], {
      account: owner.account,
    });

    try {
      await aiJudge.write.revealAnswer([bountyId, answer, wrongSalt], {
        account: alice.account,
      });
      throw new Error("Should have reverted");
    } catch (e: any) {
      if (!e.message.includes("commitment mismatch"))
        throw new Error("Expected 'commitment mismatch', got: " + e.message);
    }
  });

  it("block double reveal", async function () {
    const [owner, alice] = await viem.getWalletClients();

    const aiJudge = await viem.deployContract("AIJudge");
    const deadline = await futureDeadline(100);
    const bountyId = 1n;
    const salt = keccak256(toBytes("salt"));
    const answer = "my answer";

    await aiJudge.write.createBounty(["Test", "Rubric", deadline], {
      account: owner.account,
      value: parseEther("0.5"),
    });

    const commitment = computeCommitment(answer, salt, alice.account.address, bountyId);
    await aiJudge.write.submitCommitment([bountyId, commitment], {
      account: alice.account,
    });

    await networkHelpers.time.increase(101);
    await aiJudge.write.closeCommitPhase([bountyId], {
      account: owner.account,
    });

    // First reveal — success
    await aiJudge.write.revealAnswer([bountyId, answer, salt], {
      account: alice.account,
    });

    // Second reveal — blocked
    try {
      await aiJudge.write.revealAnswer([bountyId, answer, salt], {
        account: alice.account,
      });
      throw new Error("Should have reverted");
    } catch (e: any) {
      if (!e.message.includes("already revealed"))
        throw new Error("Expected 'already revealed', got: " + e.message);
    }
  });

  it("reject non-submitter reveal", async function () {
    const [owner, alice, eve] = await viem.getWalletClients();

    const aiJudge = await viem.deployContract("AIJudge");
    const deadline = await futureDeadline(100);
    const bountyId = 1n;
    const salt = keccak256(toBytes("salt"));
    const answer = "alice's answer";

    await aiJudge.write.createBounty(["Test", "Rubric", deadline], {
      account: owner.account,
      value: parseEther("0.5"),
    });

    const commitment = computeCommitment(answer, salt, alice.account.address, bountyId);
    await aiJudge.write.submitCommitment([bountyId, commitment], {
      account: alice.account,
    });

    await networkHelpers.time.increase(101);
    await aiJudge.write.closeCommitPhase([bountyId], {
      account: owner.account,
    });

    // Eve tries to reveal Alice's answer
    try {
      await aiJudge.write.revealAnswer([bountyId, answer, salt], {
        account: eve.account,
      });
      throw new Error("Should have reverted");
    } catch (e: any) {
      if (!e.message.includes("no commitment found"))
        throw new Error("Expected 'no commitment found', got: " + e.message);
    }
  });

  it("reject wrong answer reveal", async function () {
    const [owner, alice] = await viem.getWalletClients();

    const aiJudge = await viem.deployContract("AIJudge");
    const deadline = await futureDeadline(100);
    const bountyId = 1n;
    const salt = keccak256(toBytes("salt"));
    const answer = "correct answer";

    await aiJudge.write.createBounty(["Test", "Rubric", deadline], {
      account: owner.account,
      value: parseEther("0.5"),
    });

    const commitment = computeCommitment(answer, salt, alice.account.address, bountyId);
    await aiJudge.write.submitCommitment([bountyId, commitment], {
      account: alice.account,
    });

    await networkHelpers.time.increase(101);
    await aiJudge.write.closeCommitPhase([bountyId], {
      account: owner.account,
    });

    try {
      await aiJudge.write.revealAnswer([bountyId, "wrong answer", salt], {
        account: alice.account,
      });
      throw new Error("Should have reverted");
    } catch (e: any) {
      if (!e.message.includes("commitment mismatch"))
        throw new Error("Expected 'commitment mismatch', got: " + e.message);
    }
  });
});
