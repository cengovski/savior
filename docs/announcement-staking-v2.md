# DRAFT announcement: SAVIOR staking upgrade (not published)

**SAVIOR staking is moving to a new contract**

We are upgrading the SAVIOR staking contract on Arc. The new contract keeps everything you know: every buy still sends half of your SAVIOR to your wallet right away and locks the other half for a random 5 to 10 days. What changes is safety and control.

**Why**
The current staking contract has no working admin owner, so it can never be fixed or upgraded, and stuck tokens can never be recovered. The new contract has a proper two-step owner, no upgrade backdoor, and it can never touch your locked SAVIOR. Only the extra tokens that someone sends to it by mistake can be recovered.

**What happens**
1. We deploy the new staking contract and point the SAVIOR pool at it. From that moment, buys and sells on the site go through the new contract.
2. We unlock every position in the old contract at once. Your locked SAVIOR becomes claimable right away, no matter how much time was left.
3. You claim from the old contract and, if you want, stake into the new one. The site has a two-step "Move your old locks" card in the Locks section for this.

**Refund for an earlier staking contract**
One wallet (0xb31113cEaAd11CadBfEBE5ae8420FA09F8f1c7de) had two locks in an earlier staking contract (0xa9bd5fca5efd214fb42a5eddba87ae7e1cca9732). Those tokens were pulled out by the team with the contract's rescue function, which should not have happened. We are refunding the full locked amount, 19,668.018837 SAVIOR, as a direct token transfer from the deployer wallet. It is not staked or locked again. The refund is a separate transaction and will be linked here once sent.

**What you need to do**
- Open the site, connect your wallet and go to Locks.
- Click "1. Claim from old contract" and confirm in your wallet.
- Optional: click "2. Stake in new contract" to lock your SAVIOR again. A new lock lasts a random 5 to 10 days and the minimum is 1 SAVIOR.
- You can also just keep the claimed SAVIOR in your wallet. Your tokens stay yours either way.

**Good to know**
- Your old positions do not expire. You can claim from the old contract at any time after the unlock.
- Nobody, including the team, can move your locked SAVIOR in the new contract.
- We will never DM you or ask for your seed phrase. Only use the official site.
- New staking contract address: TBA (it will be posted here and verified on explorer.arc.io)

Questions? Ask in the official channels.
