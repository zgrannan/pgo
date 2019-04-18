# Paxos MPCal Spec
## Model Checking Values
There are five model checking values at present:
* STOP - a bound on the number of slots to decide values for
* MAXB - a bound on the maximum ballot size
* NUM_LEARNERS - the number of learners
* NUM_ACCEPTORS - the number of acceptors
* NUM_PROPOSERS - the number of proposers

Reccomended values would be: `[STOP <- 2, MAXB <- 5, NUM_LEARNERS <- 1, NUM_ACCEPTORS <- 1, NUM_PROPOSERS <- 1]` for a small quick test, and `[STOP <- 2, MAXB <- 5, NUM_LEARNERS <- 1, NUM_ACCEPTORS <- 3, NUM_PROPOSERS <- 2]` for a more thorough (but also much longer) test with concurrency.

Under advanced options, put the following as a state constraint: `\E i \in Proposer : pc[i] # "Done"`. This prevents deadlock from being detected when the proposers have run to completion.

The invariants you want to check are `Agreement` and `Agreement2`.

## Spec Details
There are three archetypes based off the thee node roles in Paxos Made Simple.
* Proposers - try to become elected leader by acquiring promises from a majority of acceptors, propose values to be accepted once they are leader
* Acceptors - respond to valid prepare messages with promises and inform nodes about the highest accepted values for each slot. Accept valid proposed values by adding it to list of highest accepted values and sending accept messages to the proposer who proposed the value and every learner.
* Learners - listen for accept messages, apply values to state machine (log archetype parameter) when chosen (majority of acceptors have agreed)