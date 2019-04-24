/--------------------------------- MODULE raftkv ---------------------------------
EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS Terms
CONSTANTS Slots
CONSTANTS NUM_NODES
CONSTANTS Follower
CONSTANTS Candidate
CONSTANTS Leader
CONSTANTS HeartBeatFrequency
ASSUME Follower # Candidate /\ Candidate # Leader /\ Follower # Leader

ASSUME NUM_NODES \in Nat

CONSTANT NULL, NULL_DB_VALUE
ASSUME NULL \notin Nat /\ NULL_DB_VALUE # NULL

CONSTANT BUFFER_SIZE
ASSUME BUFFER_SIZE \in Nat

FiniteNaturalSet(s) == IsFiniteSet(s) /\ (\A e \in s : e \in Nat)
CONSTANTS GetSet, PutSet
ASSUME FiniteNaturalSet(GetSet) /\ FiniteNaturalSet(PutSet)

\* Based on https://www.usenix.org/system/files/conference/atc14/atc14-paper-ongaro.pdf (specifically pg 5)

(***************************************************************************    
--mpcal Raft {
    define {
        \* Raft message types
        RequestVote           == 0
        RequestVoteResponse   == 1
        AppendEntries         == 2
        AppendEntriesResponse == 3
        \* Archetype sets
        Servers      == 0..NUM_NODES-1
        Heartbeats   == (NUM_NODES)..(NUM_NODES*2-1)
        KVRequests   == (2*NUM_NODES)..(3*NUM_NODES-1)
        KVManager    == (3*NUM_NODES)..(4*NUM_NODES-1)
        \* KV message types
        GET_MSG          == 4
        PUT_MSG          == 5
        GET_RESPONSE_MSG == 6
        NOT_LEADER_MSG   == 7
        OK_MSG           == 8
        \* KV operations
        GET == 9
        PUT == 10
        \* Shorthand for Raft
        Term(log,index) == (IF index > 0 /\ Len(log) >= index /\ Len(log) > 0 THEN log[index].term ELSE 0)
    }
    
    \* Invokes a RequestVote RPC on every Node
    macro SendRequestVotes(network, cterm, candidateId, lastLogIndex, lastLogTerm, idx) {
        while (idx < NUM_NODES) {
            \* granted and entries are unused, but NULL wouldn't type check
            network[idx] := [sender |-> candidateId, type |-> RequestVote, term |-> cterm, granted |-> FALSE, entries |-> <<>>,
                             prevIndex |-> lastLogIndex, prevTerm |-> lastLogTerm, commit |-> NULL];

            idx := idx + 1;
        };
    }
    
    \* Invokes an AppendEntries RPC on every Node (can serve to make progress or just as a heartbeat from the leader)
    macro SendAppendEntries(network, cterm, candidateId, nextIndex, log, leaderCommit, idx) {
        while (idx < NUM_NODES) {
            if (idx # candidateId) {
                \* granted is unused, but NULL wouldn't type check
                network[idx] := [sender |-> candidateId, type |-> AppendEntries, term |-> cterm, granted |-> FALSE, entries |-> SubSeq(log, nextIndex[idx], Len(log)),
                                 prevIndex |-> nextIndex[idx]-1, prevTerm |-> Term(log, nextIndex[idx]-1), commit |-> leaderCommit];
            };
            
            idx := idx + 1;
        };
    }

    mapping macro SelfManager {
        read  { yield self - NUM_NODES; }
        write { assert(FALSE); }
    }

    mapping macro FIFOChannel {
        read {
            await Len($variable) > 0;
            with (msg = Head($variable)) {
                $variable := Tail($variable);
                yield msg;
            };
        }

        write {
            await Len($variable) < BUFFER_SIZE;
            yield Append($variable, $value);
        }
    }

  mapping macro NextRequest {
        read {
            await Cardinality($variable) > 0;
            with (req \in $variable) {
                $variable := $variable \ {req};
                yield req;
            }
        }   

        write { assert(FALSE); yield $value; }
    }

    mapping macro SetAdd {
        read {
            with (e \in $variable) {
                $variable := $variable \ {e};
                yield e;
            }
        }

        write {
            yield $variable \union {$value};
        }
    }
    
    \* Stable FIFOQueues, returns full queue of messages
    mapping macro FIFOQueues {
        read {
            with (msgs = $variable) {
                $variable := <<>>;
                yield msgs;
            };
        }
  
        write {
            yield Append($variable, $value);
        }
    }
    
    \* Non-deterministic timeout (abstracted out of the implementation so proper timeouts can be implemented)
    mapping macro Timeout {
        read {
            either { yield FALSE; } or { yield TRUE; };
        }
  
        write { assert(FALSE); }
    }
    
    mapping macro ID {
        read { yield $variable; }
  
        write { yield $value; }
    }
    
    mapping macro Timer {
        read { assert(FALSE); }
  
        write { yield $value; }
    }
    
    \* defines semantics of unbuffered Go channels
    mapping macro UnbufferedChannel {
        read {
            await $variable.value # NULL;
            with (v = $variable) {
                $variable.value := NULL;
                yield v;
            }
        }
        write {
            await $variable.value = NULL;
            yield $value;
        }
    }

    archetype KeyValueRequests(requests, ref upstream, iAmTheLeader, ref proposerChan, raftChan)
    variables msg, null, heartbeatId, proposerId, counter = 0, requestId, proposal, result;
    {
      kvInit:
        heartbeatId := self - NUM_NODES;
        proposerId := self - 2*NUM_NODES;
      kvLoop:
        while (TRUE) {
            msg := requests;
            assert(msg.type = GET_MSG \/ msg.type = PUT_MSG);
            if (iAmTheLeader[heartbeatId]) {
                \* request that this operation be proposed by the underlying proposer
                \* unique request identifier
                requestId := << self, counter >>;
                if (msg.type = GET_MSG) {
                    proposal := [operation |-> GET, id |-> requestId, key |-> msg.key, value |-> msg.key];
                } else {
                    proposal := [operation |-> PUT, id |-> requestId, key |-> msg.key, value |-> msg.value];
                };
                \* divergence from Paxos spec: no function application in proposerChan
                proposerChan[proposerId] := proposal;
                result := raftChan[self];
                upstream := [type |-> OK_MSG, result |-> result];
                counter := counter + 1;
            } else {
                upstream := [type |-> NOT_LEADER_MSG, result |-> null];
            }
        }
    }

    archetype KeyValueRaftManager(ref requestService, learnerChan, ref db, kvId)
    variables result, learnerId, decided;
    {
      findId:
        learnerId := self - 3*NUM_NODES;
      kvManagerLoop:
        while (TRUE) {
            \* wait for a value to be informed by the learner
            decided := learnerChan[learnerId];
            \* always update the database if it's a PUT request, regardless of whether
            \* this instance issued the request
            if (decided.operation = PUT) {
                db[<< kvId, decided.key >>] := decided.value;
            };
            \* only send the result to the request service if we issued the request
            if (decided.id[1] = kvId) {
                \* read value from the database and return result
                if (decided.operation = GET) {
                    result := db[<< kvId, decided.key >>];
                } else {
                    result := decided.value;
                };
                requestService[kvId] := result;
            };
        }
    }
    
    archetype Heartbeat(ref network, iAmTheLeader, term, ref timer, nextIndexIn, logIn, commitIn)
    variable index, next = [s \in Servers |-> NULL]; {
      HBLoop: 
        while (TRUE) {
          CheckHeartBeat:
            await(iAmTheLeader[self]);
    
          SendHeartBeatLoop:
            while (iAmTheLeader[self]) {
                \* Sleep for 500 ms
                timer := HeartBeatFrequency;
                index := 0;
                \* Must be read into local so PGo learns type
                next := nextIndexIn[self - NUM_NODES];
        
                \* Make AppendEntries RPC calls to every other node (as a heartbeat and to notify them of new entries)
              SendHeartBeats:
                SendAppendEntries(network, term[self - NUM_NODES], self - NUM_NODES, next, logIn[self - NUM_NODES], commitIn[self - NUM_NODES], index);
            };
        };
    }

    archetype Node(ref network, ref applied, input, timeout, ref iAmTheLeader, ref term, ref lastmsg, ref nextChan, ref logChan, ref commitChan)
    \* Every variable should be name correspondingly with those described on page 5 of the Ongaro paper
    variable currentTerm = 0,
             votedFor = NULL,
             log = <<>>,
             state = Follower,
             commitIndex = 0,
             lastApplied = 0,
             nextIndex,
             matchIndex,
             iterator,
             votes = [t \in 0..Terms |-> {}],
             \* The following are temporary state:
             value,
             msg,
             response,
             msgs; {
      NodeLoop: 
        while (TRUE) {
          TimeoutCheck:
            if (state # Leader /\ timeout) { \* Election timeout, become candidate
                state := Candidate;
                \* Increment term
                currentTerm := currentTerm + 1;
                \* Vote for self
                votes[currentTerm] := {self};
                votedFor := self;
                iterator := 0;
    
SendReqVotes:   SendRequestVotes(network, currentTerm, self, Len(log), Term(log, Len(log)), iterator);
            };
    
          LeaderCheck:
            \* TODO: check for value before broadcasting
            if (state = Leader) { \* I am the leader for the currentTerm
                \* Make progress (append to the log)
GetVal:         value := input[self];
                log := Append(log, [val |-> value, term |-> currentTerm]);
    
                matchIndex[self] := Len(log);
                nextIndex[self] := Len(log)+1;
                logChan[self] := log;
                nextChan[self] := nextIndex;

                \* Can we commit more entries?
AdvanceIndex:   while (Cardinality({i \in Servers: matchIndex[i] > commitIndex})*2 > Cardinality(Servers) /\ Term(log, commitIndex+1) = currentTerm) {
                    commitIndex := commitIndex + 1;
                };
                
UpdateCommit:   commitChan[self] := commitIndex;

                \* Apply newly commited values
ApplyCommited:  while(lastApplied < commitIndex) {
                    lastApplied := lastApplied + 1;
                    applied[self] := log[lastApplied].val;
                };
    
                iterator := 0;
    
              SendAppendEntries:
                \* Make AppendEntries RPC calls to every other node (as a heartbeat and to notify them of new entries)
                SendAppendEntries(network, currentTerm, self, nextIndex, log, commitIndex, iterator);
            };
    
            \* Handle messages
RecvMsg:    msgs := network[self];
    
          ProcessMsgs:
            while (Len(msgs) > 0) {
GetMsg:         msg := Head(msgs);
                msgs := Tail(msgs);

CheckMsgTerm:   if (msg.term > currentTerm) { \* If hearing of a later term, someone else must be the leader for that term
                    iAmTheLeader[self + NUM_NODES] := FALSE;
                    state := Follower;
                    currentTerm := msg.term;
                    \* Haven't voted for anyone in the new term
                    votedFor := NULL;
                };
            
                \* Implements RPC request and response logic in figure 5
MsgSwitch:      if (msg.type = AppendEntries) {
                    response := [sender |-> self, type |-> AppendEntriesResponse, term |-> currentTerm, granted |-> FALSE,
                                 entries |-> <<>>, prevIndex |-> NULL, prevTerm |-> NULL, commit |-> NULL];

                    if ((msg.term >= currentTerm) /\ ((msg.prevIndex > 0 /\ Len(log) > msg.prevIndex)
                                                      \/ Term(log, msg.prevIndex) # msg.prevTerm)) {
                        \* Following entries don't have matching terms
                        assert(state # Leader);
                        \* Delete entries that don't match
                        log := SubSeq(log, 1, msg.prevIndex-1);
                        lastmsg := msg;
                    } elseif (msg.term >= currentTerm) {
                        \* Append new entries
                        if (Len(log) = msg.prevIndex) {
                            log := log \o msg.entries;
                        };

AEValid:                response := [sender |-> self, type |-> AppendEntriesResponse, term |-> currentTerm, granted |-> TRUE,
                                     entries |-> <<>>, prevIndex |-> Len(log), prevTerm |-> NULL, commit |-> NULL];
                        lastmsg := msg;
                    };
    
AESendResponse:     network[msg.sender] := response;
    
                    if (msg.commit > commitIndex) { \* Maybe we can commit more entries
                        commitIndex := IF msg.commit < Len(log) THEN msg.commit ELSE Len(log);
    
AEApplyCommitted:       while(lastApplied < commitIndex) {
                            lastApplied := lastApplied + 1;
                            applied[self] := log[lastApplied].val;
                        };
                    };
                } elseif (msg.type = RequestVote) {
                    response := [sender |-> self, type |-> RequestVoteResponse, term |-> currentTerm, granted |-> FALSE,
                                 entries |-> <<>>, prevIndex |-> NULL, prevTerm |-> NULL, commit |-> NULL];

                    \* Check if the candidate's log is at least as up-to-date as ours, and we haven't voted for someone else
                    if ((votedFor = NULL \/ votedFor = msg.sender)
                        /\ (msg.term >= currentTerm)
                        /\ (msg.prevTerm > Term(log, Len(log))
                           \/ (msg.prevTerm = Term(log, Len(log)) /\ msg.prevIndex >= Len(log)))) {
                        \* Have to overwrite entire response cause PGo doesn't support overwriting record entries
RVValid:                response := [sender |-> self, type |-> RequestVoteResponse, term |-> currentTerm, granted |-> TRUE,
                                     entries |-> <<>>, prevIndex |-> NULL, prevTerm |-> NULL, commit |-> NULL];
                        votedFor := msg.sender;
                    };

RVSendResponse:    network[msg.sender] := response;
                } elseif (msg.type = AppendEntriesResponse /\ msg.term = currentTerm /\ state = Leader) {
AERCheckGranted:    if (msg.granted) { \* They successfully added all entries! Update index we have recorded for them
                        nextIndex[msg.sender] := msg.prevIndex + 1;
                        matchIndex[msg.sender] := msg.prevIndex;
                        nextChan[self] := nextIndex;
                    } else {
                        \* The append was rejected, try again with the previous index
                        nextIndex[msg.sender] := IF nextIndex[msg.sender] - 1 > 1 THEN nextIndex[msg.sender] - 1 ELSE 1;
    
RetryAppendEntry:       network[msg.sender] := [sender |-> self, type |-> RequestVote, term |-> currentTerm, granted |-> FALSE, entries |-> SubSeq(log, nextIndex[msg.sender], Len(log)),
                                                prevIndex |-> nextIndex[msg.sender]-1, prevTerm |-> Term(log, nextIndex[msg.sender]-1), commit |-> commitIndex];
                        nextChan[self] := nextIndex;
                    };
                } elseif (msg.type = RequestVoteResponse /\ msg.term = currentTerm /\ state = Candidate) {
                    if (msg.granted) { \* This server has received an additional vote
                        votes[msg.term] := votes[msg.term] \union {msg.sender};
                        if (Cardinality(votes[msg.term])*2 > Cardinality(Servers)) {
                            \* Voters form a quorum!
BecomeLeader:               iAmTheLeader[self + NUM_NODES] := TRUE;
                            term[self] := currentTerm;
                            logChan[self] := log;
                            commitChan[self] := commitIndex;
                            state := Leader;
                            \* Re-initialize volatile state
                            matchIndex := [s3 \in Servers |-> 0];
                            nextIndex := [s4 \in Servers |-> 1];
                            \* Initial empty AppendEntry heartbeats are handled by HeartBeat archetype
                            nextChan[self] := nextIndex;
                        };
                    };
                };
            };
        };
    }

    variables
        values = [k \in Servers |-> <<>>],
        \* requests to be sent by the client
        requestSet = { [type |-> GET_MSG, key |-> k, value |-> NULL] : k \in GetSet } \union { [type |-> PUT_MSG, key |-> v, value |-> v] : v \in PutSet},
        learnedChan = [l \in Servers |-> <<>>],
        raftLayerChan = [p \in KVRequests |-> <<>>],
        kvClient = {},
        idAbstract,
        database = [p \in KVRequests, k \in GetSet \union PutSet |-> NULL_DB_VALUE],
        iAmTheLeaderAbstract = [h \in Heartbeats |-> FALSE],
        \* Used in Raft:
        frequency = 500,
        terms = [s \in Servers |-> NULL],
        lastSeen,
        nexts = [x \in Servers |-> [s \in Servers |-> NULL]],
        logs = [s \in Servers |-> NULL],
        commits = [s \in Servers |-> NULL],
        mailboxes = [id \in Servers |-> <<>>];

    fair process (kvRequests \in KVRequests) == instance KeyValueRequests(requestSet, ref kvClient, iAmTheLeaderAbstract, ref values, raftLayerChan)
        mapping requestSet via NextRequest
        mapping kvClient via SetAdd
        mapping iAmTheLeaderAbstract[_] via ID
        mapping values[_] via FIFOChannel
        mapping raftLayerChan[_] via FIFOChannel;
    fair process (kvManager \in KVManager) == instance KeyValueRaftManager(ref raftLayerChan, learnedChan, ref database, idAbstract)
        mapping raftLayerChan[_] via FIFOChannel
        mapping learnedChan[_] via FIFOChannel
        mapping database[_] via ID
        mapping idAbstract via SelfManager;
    fair process (server \in Servers) == instance Node(ref mailboxes, learnedChan, values, TRUE, ref iAmTheLeaderAbstract, ref terms, ref lastSeen, ref nexts, ref logs, ref commits)
        mapping mailboxes[_] via FIFOQueues
        mapping learnedChan[_] via FIFOChannel
        mapping values[_] via FIFOChannel
        mapping @4 via Timeout
        mapping iAmTheLeaderAbstract[_] via ID
        mapping terms[_] via ID
        mapping lastSeen via ID
        mapping nexts[_] via ID
        mapping logs[_] via ID
        mapping commits[_] via ID;

    fair process (heartbeat \in Heartbeats) == instance Heartbeat(ref mailboxes, iAmTheLeaderAbstract, terms, ref frequency, nexts, logs, commits)
        mapping mailboxes[_] via FIFOQueues
        mapping iAmTheLeaderAbstract[_] via ID
        mapping terms[_] via ID
        mapping frequency via Timer
        mapping nexts[_] via ID
        mapping logs[_] via ID
        mapping commits[_] via ID;

}


\* BEGIN PLUSCAL TRANSLATION
--algorithm Raft {
    variables values = [k \in Servers |-> <<>>], requestSet = ({[type |-> GET_MSG, key |-> k, value |-> NULL] : k \in GetSet}) \union ({[type |-> PUT_MSG, key |-> v, value |-> v] : v \in PutSet}), learnedChan = [l \in Servers |-> <<>>], raftLayerChan = [p \in KVRequests |-> <<>>], kvClient = {}, idAbstract, database = [p \in KVRequests, k \in (GetSet) \union (PutSet) |-> NULL_DB_VALUE], iAmTheLeaderAbstract = [h \in Heartbeats |-> FALSE], frequency = 500, terms = [s \in Servers |-> NULL], lastSeen, nexts = [x \in Servers |-> [s \in Servers |-> NULL]], logs = [s \in Servers |-> NULL], commits = [s \in Servers |-> NULL], mailboxes = [id \in Servers |-> <<>>], requestsRead, requestsWrite, iAmTheLeaderRead, proposerChanWrite, raftChanRead, raftChanWrite, upstreamWrite, proposerChanWrite0, raftChanWrite0, upstreamWrite0, requestsWrite0, proposerChanWrite1, raftChanWrite1, upstreamWrite1, learnerChanRead, learnerChanWrite, kvIdRead, dbWrite, dbWrite0, kvIdRead0, kvIdRead1, dbRead, kvIdRead2, requestServiceWrite, requestServiceWrite0, learnerChanWrite0, dbWrite1, requestServiceWrite1, timeoutRead, networkWrite, networkWrite0, networkWrite1, inputRead, inputWrite, logChanWrite, nextChanWrite, commitChanWrite, appliedWrite, appliedWrite0, networkWrite2, networkWrite3, inputWrite0, logChanWrite0, nextChanWrite0, commitChanWrite0, appliedWrite1, networkWrite4, networkRead, iAmTheLeaderWrite, iAmTheLeaderWrite0, lastmsgWrite, lastmsgWrite0, lastmsgWrite1, ifResult, appliedWrite2, appliedWrite3, ifResult0, nextChanWrite1, networkWrite5, termWrite, iAmTheLeaderWrite1, termWrite0, logChanWrite1, commitChanWrite1, nextChanWrite2, iAmTheLeaderWrite2, termWrite1, logChanWrite2, commitChanWrite2, nextChanWrite3, iAmTheLeaderWrite3, termWrite2, logChanWrite3, commitChanWrite3, nextChanWrite4, nextChanWrite5, networkWrite6, iAmTheLeaderWrite4, termWrite3, logChanWrite4, commitChanWrite4, networkWrite7, nextChanWrite6, iAmTheLeaderWrite5, termWrite4, logChanWrite5, commitChanWrite5, lastmsgWrite2, networkWrite8, appliedWrite4, nextChanWrite7, iAmTheLeaderWrite6, termWrite5, logChanWrite6, commitChanWrite6, iAmTheLeaderWrite7, lastmsgWrite3, networkWrite9, appliedWrite5, nextChanWrite8, termWrite6, logChanWrite7, commitChanWrite7, networkWrite10, inputWrite1, logChanWrite8, nextChanWrite9, commitChanWrite8, appliedWrite6, iAmTheLeaderWrite8, lastmsgWrite4, termWrite7, iAmTheLeaderRead0, timerWrite, nextIndexInRead, termRead, logInRead, logInRead0, logInRead1, commitInRead, networkWrite11, networkWrite12, networkWrite13, timerWrite0, networkWrite14, timerWrite1, networkWrite15;
    define {
        RequestVote == 0
        RequestVoteResponse == 1
        AppendEntries == 2
        AppendEntriesResponse == 3
        Servers == (0) .. ((NUM_NODES) - (1))
        Heartbeats == (NUM_NODES) .. (((NUM_NODES) * (2)) - (1))
        KVRequests == ((2) * (NUM_NODES)) .. (((3) * (NUM_NODES)) - (1))
        KVManager == ((3) * (NUM_NODES)) .. (((4) * (NUM_NODES)) - (1))
        GET_MSG == 4
        PUT_MSG == 5
        GET_RESPONSE_MSG == 6
        NOT_LEADER_MSG == 7
        OK_MSG == 8
        GET == 9
        PUT == 10
        Term(log, index) == IF (((index) > (0)) /\ ((Len(log)) >= (index))) /\ ((Len(log)) > (0)) THEN (log[index]).term ELSE 0
    }
    fair process (kvRequests \in KVRequests)
    variables msg, null, heartbeatId, proposerId, counter = 0, requestId, proposal, result;
    {
        kvInit:
            heartbeatId := (self) - (NUM_NODES);
            proposerId := (self) - ((2) * (NUM_NODES));
        kvLoop:
            if (TRUE) {
                await (Cardinality(requestSet)) > (0);
                with (req0 \in requestSet) {
                    requestsWrite := (requestSet) \ ({req0});
                    requestsRead := req0;
                };
                msg := requestsRead;
                assert (((msg).type) = (GET_MSG)) \/ (((msg).type) = (PUT_MSG));
                iAmTheLeaderRead := iAmTheLeaderAbstract[heartbeatId];
                if (iAmTheLeaderRead) {
                    requestId := <<self, counter>>;
                    if (((msg).type) = (GET_MSG)) {
                        proposal := [operation |-> GET, id |-> requestId, key |-> (msg).key, value |-> (msg).key];
                    } else {
                        proposal := [operation |-> PUT, id |-> requestId, key |-> (msg).key, value |-> (msg).value];
                    };
                    await (Len(values[proposerId])) < (BUFFER_SIZE);
                    proposerChanWrite := [values EXCEPT ![proposerId] = Append(values[proposerId], proposal)];
                    await (Len(raftLayerChan[self])) > (0);
                    with (msg0 = Head(raftLayerChan[self])) {
                        raftChanWrite := [raftLayerChan EXCEPT ![self] = Tail(raftLayerChan[self])];
                        raftChanRead := msg0;
                    };
                    result := raftChanRead;
                    upstreamWrite := (kvClient) \union ({[type |-> OK_MSG, result |-> result]});
                    counter := (counter) + (1);
                    proposerChanWrite0 := proposerChanWrite;
                    raftChanWrite0 := raftChanWrite;
                    upstreamWrite0 := upstreamWrite;
                    requestsWrite0 := requestsWrite;
                    proposerChanWrite1 := proposerChanWrite0;
                    raftChanWrite1 := raftChanWrite0;
                    upstreamWrite1 := upstreamWrite0;
                    requestSet := requestsWrite0;
                    kvClient := upstreamWrite1;
                    values := proposerChanWrite1;
                    raftLayerChan := raftChanWrite1;
                    goto kvLoop;
                } else {
                    upstreamWrite := (kvClient) \union ({[type |-> NOT_LEADER_MSG, result |-> null]});
                    proposerChanWrite0 := values;
                    raftChanWrite0 := raftLayerChan;
                    upstreamWrite0 := upstreamWrite;
                    requestsWrite0 := requestsWrite;
                    proposerChanWrite1 := proposerChanWrite0;
                    raftChanWrite1 := raftChanWrite0;
                    upstreamWrite1 := upstreamWrite0;
                    requestSet := requestsWrite0;
                    kvClient := upstreamWrite1;
                    values := proposerChanWrite1;
                    raftLayerChan := raftChanWrite1;
                    goto kvLoop;
                };
            } else {
                requestsWrite0 := requestSet;
                proposerChanWrite1 := values;
                raftChanWrite1 := raftLayerChan;
                upstreamWrite1 := kvClient;
                requestSet := requestsWrite0;
                kvClient := upstreamWrite1;
                values := proposerChanWrite1;
                raftLayerChan := raftChanWrite1;
            };
    
    }
    fair process (kvManager \in KVManager)
    variables result, learnerId, decided;
    {
        findId:
            learnerId := (self) - ((3) * (NUM_NODES));
        kvManagerLoop:
            if (TRUE) {
                await (Len(learnedChan[learnerId])) > (0);
                with (msg1 = Head(learnedChan[learnerId])) {
                    learnerChanWrite := [learnedChan EXCEPT ![learnerId] = Tail(learnedChan[learnerId])];
                    learnerChanRead := msg1;
                };
                decided := learnerChanRead;
                if (((decided).operation) = (PUT)) {
                    kvIdRead := (self) - (NUM_NODES);
                    dbWrite := [database EXCEPT ![<<kvIdRead, (decided).key>>] = (decided).value];
                    dbWrite0 := dbWrite;
                } else {
                    dbWrite0 := database;
                };
                kvIdRead0 := (self) - (NUM_NODES);
                if (((decided).id[1]) = (kvIdRead0)) {
                    if (((decided).operation) = (GET)) {
                        kvIdRead1 := (self) - (NUM_NODES);
                        dbRead := dbWrite0[<<kvIdRead1, (decided).key>>];
                        result := dbRead;
                    } else {
                        result := (decided).value;
                    };
                    kvIdRead2 := (self) - (NUM_NODES);
                    await (Len(raftLayerChan[kvIdRead2])) < (BUFFER_SIZE);
                    requestServiceWrite := [raftLayerChan EXCEPT ![kvIdRead2] = Append(raftLayerChan[kvIdRead2], result)];
                    requestServiceWrite0 := requestServiceWrite;
                    learnerChanWrite0 := learnerChanWrite;
                    dbWrite1 := dbWrite0;
                    requestServiceWrite1 := requestServiceWrite0;
                    raftLayerChan := requestServiceWrite1;
                    learnedChan := learnerChanWrite0;
                    database := dbWrite1;
                    goto kvManagerLoop;
                } else {
                    requestServiceWrite0 := raftLayerChan;
                    learnerChanWrite0 := learnerChanWrite;
                    dbWrite1 := dbWrite0;
                    requestServiceWrite1 := requestServiceWrite0;
                    raftLayerChan := requestServiceWrite1;
                    learnedChan := learnerChanWrite0;
                    database := dbWrite1;
                    goto kvManagerLoop;
                };
            } else {
                learnerChanWrite0 := learnedChan;
                dbWrite1 := database;
                requestServiceWrite1 := raftLayerChan;
                raftLayerChan := requestServiceWrite1;
                learnedChan := learnerChanWrite0;
                database := dbWrite1;
            };
    
    }
    fair process (server \in Servers)
    variables timeoutLocal = TRUE, currentTerm = 0, votedFor = NULL, log = <<>>, state = Follower, commitIndex = 0, lastApplied = 0, nextIndex, matchIndex, iterator, votes = [t \in (0) .. (Terms) |-> {}], value, msg, response, msgs;
    {
        NodeLoop:
            if (TRUE) {
                TimeoutCheck:
                    either {
                        timeoutRead := FALSE;
                    } or {
                        timeoutRead := TRUE;
                    };
                    if (((state) # (Leader)) /\ (timeoutRead)) {
                        state := Candidate;
                        currentTerm := (currentTerm) + (1);
                        votes[currentTerm] := {self};
                        votedFor := self;
                        iterator := 0;
                        SendReqVotes:
                            if ((iterator) < (NUM_NODES)) {
                                networkWrite := [mailboxes EXCEPT ![iterator] = Append(mailboxes[iterator], [sender |-> self, type |-> RequestVote, term |-> currentTerm, granted |-> FALSE, entries |-> <<>>, prevIndex |-> Len(log), prevTerm |-> Term(log, Len(log)), commit |-> NULL])];
                                iterator := (iterator) + (1);
                                networkWrite0 := networkWrite;
                                mailboxes := networkWrite0;
                                goto SendReqVotes;
                            } else {
                                networkWrite0 := mailboxes;
                                mailboxes := networkWrite0;
                            };
                    
                    } else {
                        networkWrite1 := mailboxes;
                        mailboxes := networkWrite1;
                    };
                
                LeaderCheck:
                    if ((state) = (Leader)) {
                        GetVal:
                            await (Len(values[self])) > (0);
                            with (msg2 = Head(values[self])) {
                                inputWrite := [values EXCEPT ![self] = Tail(values[self])];
                                inputRead := msg2;
                            };
                            value := inputRead;
                            log := Append(log, [val |-> value, term |-> currentTerm]);
                            matchIndex[self] := Len(log);
                            nextIndex[self] := (Len(log)) + (1);
                            logChanWrite := [logs EXCEPT ![self] = log];
                            nextChanWrite := [nexts EXCEPT ![self] = nextIndex];
                            values := inputWrite;
                            nexts := nextChanWrite;
                            logs := logChanWrite;
                        
                        AdvanceIndex:
                            if ((((Cardinality({i \in Servers : (matchIndex[i]) > (commitIndex)})) * (2)) > (Cardinality(Servers))) /\ ((Term(log, (commitIndex) + (1))) = (currentTerm))) {
                                commitIndex := (commitIndex) + (1);
                                goto AdvanceIndex;
                            };
                        
                        UpdateCommit:
                            commitChanWrite := [commits EXCEPT ![self] = commitIndex];
                            commits := commitChanWrite;
                        
                        ApplyCommited:
                            if ((lastApplied) < (commitIndex)) {
                                lastApplied := (lastApplied) + (1);
                                await (Len(learnedChan[self])) < (BUFFER_SIZE);
                                appliedWrite := [learnedChan EXCEPT ![self] = Append(learnedChan[self], (log[lastApplied]).val)];
                                appliedWrite0 := appliedWrite;
                                learnedChan := appliedWrite0;
                                goto ApplyCommited;
                            } else {
                                iterator := 0;
                                appliedWrite0 := learnedChan;
                                learnedChan := appliedWrite0;
                            };
                        
                        SendAppendEntries:
                            if ((iterator) < (NUM_NODES)) {
                                if ((iterator) # (self)) {
                                    networkWrite := [mailboxes EXCEPT ![iterator] = Append(mailboxes[iterator], [sender |-> self, type |-> AppendEntries, term |-> currentTerm, granted |-> FALSE, entries |-> SubSeq(log, nextIndex[iterator], Len(log)), prevIndex |-> (nextIndex[iterator]) - (1), prevTerm |-> Term(log, (nextIndex[iterator]) - (1)), commit |-> commitIndex])];
                                    networkWrite2 := networkWrite;
                                } else {
                                    networkWrite2 := mailboxes;
                                };
                                iterator := (iterator) + (1);
                                networkWrite3 := networkWrite2;
                                mailboxes := networkWrite3;
                                goto SendAppendEntries;
                            } else {
                                networkWrite3 := mailboxes;
                                mailboxes := networkWrite3;
                            };
                    
                    } else {
                        inputWrite0 := values;
                        logChanWrite0 := logs;
                        nextChanWrite0 := nexts;
                        commitChanWrite0 := commits;
                        appliedWrite1 := learnedChan;
                        networkWrite4 := mailboxes;
                        mailboxes := networkWrite4;
                        learnedChan := appliedWrite1;
                        values := inputWrite0;
                        nexts := nextChanWrite0;
                        logs := logChanWrite0;
                        commits := commitChanWrite0;
                    };
                
                RecvMsg:
                    with (msgs0 = mailboxes[self]) {
                        networkWrite := [mailboxes EXCEPT ![self] = <<>>];
                        networkRead := msgs0;
                    };
                    msgs := networkRead;
                    mailboxes := networkWrite;
                
                ProcessMsgs:
                    if ((Len(msgs)) > (0)) {
                        GetMsg:
                            msg := Head(msgs);
                            msgs := Tail(msgs);
                        
                        CheckMsgTerm:
                            if (((msg).term) > (currentTerm)) {
                                iAmTheLeaderWrite := [iAmTheLeaderAbstract EXCEPT ![(self) + (NUM_NODES)] = FALSE];
                                state := Follower;
                                currentTerm := (msg).term;
                                votedFor := NULL;
                                iAmTheLeaderWrite0 := iAmTheLeaderWrite;
                                iAmTheLeaderAbstract := iAmTheLeaderWrite0;
                            } else {
                                iAmTheLeaderWrite0 := iAmTheLeaderAbstract;
                                iAmTheLeaderAbstract := iAmTheLeaderWrite0;
                            };
                        
                        MsgSwitch:
                            if (((msg).type) = (AppendEntries)) {
                                response := [sender |-> self, type |-> AppendEntriesResponse, term |-> currentTerm, granted |-> FALSE, entries |-> <<>>, prevIndex |-> NULL, prevTerm |-> NULL, commit |-> NULL];
                                if ((((msg).term) >= (currentTerm)) /\ (((((msg).prevIndex) > (0)) /\ ((Len(log)) > ((msg).prevIndex))) \/ ((Term(log, (msg).prevIndex)) # ((msg).prevTerm)))) {
                                    assert (state) # (Leader);
                                    log := SubSeq(log, 1, ((msg).prevIndex) - (1));
                                    lastmsgWrite := msg;
                                    lastmsgWrite1 := lastmsgWrite;
                                    lastSeen := lastmsgWrite1;
                                } else {
                                    if (((msg).term) >= (currentTerm)) {
                                        if ((Len(log)) = ((msg).prevIndex)) {
                                            log := (log) \o ((msg).entries);
                                        };
                                        AEValid:
                                            response := [sender |-> self, type |-> AppendEntriesResponse, term |-> currentTerm, granted |-> TRUE, entries |-> <<>>, prevIndex |-> Len(log), prevTerm |-> NULL, commit |-> NULL];
                                            lastmsgWrite := msg;
                                            lastSeen := lastmsgWrite;
                                    
                                    } else {
                                        lastmsgWrite0 := lastSeen;
                                        lastmsgWrite1 := lastmsgWrite0;
                                        lastSeen := lastmsgWrite1;
                                    };
                                };
                                AESendResponse:
                                    networkWrite := [mailboxes EXCEPT ![(msg).sender] = Append(mailboxes[(msg).sender], response)];
                                    if (((msg).commit) > (commitIndex)) {
                                        if (((msg).commit) < (Len(log))) {
                                            ifResult := (msg).commit;
                                        } else {
                                            ifResult := Len(log);
                                        };
                                        commitIndex := ifResult;
                                        mailboxes := networkWrite;
                                        AEApplyCommitted:
                                            if ((lastApplied) < (commitIndex)) {
                                                lastApplied := (lastApplied) + (1);
                                                await (Len(learnedChan[self])) < (BUFFER_SIZE);
                                                appliedWrite := [learnedChan EXCEPT ![self] = Append(learnedChan[self], (log[lastApplied]).val)];
                                                appliedWrite2 := appliedWrite;
                                                learnedChan := appliedWrite2;
                                                goto AEApplyCommitted;
                                            } else {
                                                appliedWrite2 := learnedChan;
                                                learnedChan := appliedWrite2;
                                                goto ProcessMsgs;
                                            };
                                    
                                    } else {
                                        appliedWrite3 := learnedChan;
                                        mailboxes := networkWrite;
                                        learnedChan := appliedWrite3;
                                        goto ProcessMsgs;
                                    };
                            
                            } else {
                                if (((msg).type) = (RequestVote)) {
                                    response := [sender |-> self, type |-> RequestVoteResponse, term |-> currentTerm, granted |-> FALSE, entries |-> <<>>, prevIndex |-> NULL, prevTerm |-> NULL, commit |-> NULL];
                                    if (((((votedFor) = (NULL)) \/ ((votedFor) = ((msg).sender))) /\ (((msg).term) >= (currentTerm))) /\ ((((msg).prevTerm) > (Term(log, Len(log)))) \/ ((((msg).prevTerm) = (Term(log, Len(log)))) /\ (((msg).prevIndex) >= (Len(log)))))) {
                                        RVValid:
                                            response := [sender |-> self, type |-> RequestVoteResponse, term |-> currentTerm, granted |-> TRUE, entries |-> <<>>, prevIndex |-> NULL, prevTerm |-> NULL, commit |-> NULL];
                                            votedFor := (msg).sender;
                                    
                                    };
                                    RVSendResponse:
                                        networkWrite := [mailboxes EXCEPT ![(msg).sender] = Append(mailboxes[(msg).sender], response)];
                                        mailboxes := networkWrite;
                                        goto ProcessMsgs;
                                
                                } else {
                                    if (((((msg).type) = (AppendEntriesResponse)) /\ (((msg).term) = (currentTerm))) /\ ((state) = (Leader))) {
                                        AERCheckGranted:
                                            if ((msg).granted) {
                                                nextIndex[msg.sender] := ((msg).prevIndex) + (1);
                                                matchIndex[msg.sender] := (msg).prevIndex;
                                                nextChanWrite := [nexts EXCEPT ![self] = nextIndex];
                                                nextChanWrite1 := nextChanWrite;
                                                networkWrite5 := mailboxes;
                                                mailboxes := networkWrite5;
                                                nexts := nextChanWrite1;
                                                goto ProcessMsgs;
                                            } else {
                                                if (((nextIndex[(msg).sender]) - (1)) > (1)) {
                                                    ifResult0 := (nextIndex[(msg).sender]) - (1);
                                                } else {
                                                    ifResult0 := 1;
                                                };
                                                nextIndex[msg.sender] := ifResult0;
                                                RetryAppendEntry:
                                                    networkWrite := [mailboxes EXCEPT ![(msg).sender] = Append(mailboxes[(msg).sender], [sender |-> self, type |-> RequestVote, term |-> currentTerm, granted |-> FALSE, entries |-> SubSeq(log, nextIndex[(msg).sender], Len(log)), prevIndex |-> (nextIndex[(msg).sender]) - (1), prevTerm |-> Term(log, (nextIndex[(msg).sender]) - (1)), commit |-> commitIndex])];
                                                    nextChanWrite := [nexts EXCEPT ![self] = nextIndex];
                                                    mailboxes := networkWrite;
                                                    nexts := nextChanWrite;
                                                    goto ProcessMsgs;
                                            
                                            };
                                    
                                    } else {
                                        if (((((msg).type) = (RequestVoteResponse)) /\ (((msg).term) = (currentTerm))) /\ ((state) = (Candidate))) {
                                            if ((msg).granted) {
                                                votes[msg.term] := (votes[(msg).term]) \union ({(msg).sender});
                                                if (((Cardinality(votes[(msg).term])) * (2)) > (Cardinality(Servers))) {
                                                    BecomeLeader:
                                                        iAmTheLeaderWrite := [iAmTheLeaderAbstract EXCEPT ![(self) + (NUM_NODES)] = TRUE];
                                                        termWrite := [terms EXCEPT ![self] = currentTerm];
                                                        logChanWrite := [logs EXCEPT ![self] = log];
                                                        commitChanWrite := [commits EXCEPT ![self] = commitIndex];
                                                        state := Leader;
                                                        matchIndex := [s3 \in Servers |-> 0];
                                                        nextIndex := [s4 \in Servers |-> 1];
                                                        nextChanWrite := [nexts EXCEPT ![self] = nextIndex];
                                                        iAmTheLeaderAbstract := iAmTheLeaderWrite;
                                                        terms := termWrite;
                                                        nexts := nextChanWrite;
                                                        logs := logChanWrite;
                                                        commits := commitChanWrite;
                                                        goto ProcessMsgs;
                                                
                                                } else {
                                                    iAmTheLeaderWrite1 := iAmTheLeaderAbstract;
                                                    termWrite0 := terms;
                                                    logChanWrite1 := logs;
                                                    commitChanWrite1 := commits;
                                                    nextChanWrite2 := nexts;
                                                    iAmTheLeaderWrite2 := iAmTheLeaderWrite1;
                                                    termWrite1 := termWrite0;
                                                    logChanWrite2 := logChanWrite1;
                                                    commitChanWrite2 := commitChanWrite1;
                                                    nextChanWrite3 := nextChanWrite2;
                                                    iAmTheLeaderWrite3 := iAmTheLeaderWrite2;
                                                    termWrite2 := termWrite1;
                                                    logChanWrite3 := logChanWrite2;
                                                    commitChanWrite3 := commitChanWrite2;
                                                    nextChanWrite4 := nextChanWrite3;
                                                    nextChanWrite5 := nextChanWrite4;
                                                    networkWrite6 := mailboxes;
                                                    iAmTheLeaderWrite4 := iAmTheLeaderWrite3;
                                                    termWrite3 := termWrite2;
                                                    logChanWrite4 := logChanWrite3;
                                                    commitChanWrite4 := commitChanWrite3;
                                                    networkWrite7 := networkWrite6;
                                                    nextChanWrite6 := nextChanWrite5;
                                                    iAmTheLeaderWrite5 := iAmTheLeaderWrite4;
                                                    termWrite4 := termWrite3;
                                                    logChanWrite5 := logChanWrite4;
                                                    commitChanWrite5 := commitChanWrite4;
                                                    lastmsgWrite2 := lastSeen;
                                                    networkWrite8 := networkWrite7;
                                                    appliedWrite4 := learnedChan;
                                                    nextChanWrite7 := nextChanWrite6;
                                                    iAmTheLeaderWrite6 := iAmTheLeaderWrite5;
                                                    termWrite5 := termWrite4;
                                                    logChanWrite6 := logChanWrite5;
                                                    commitChanWrite6 := commitChanWrite5;
                                                    mailboxes := networkWrite8;
                                                    learnedChan := appliedWrite4;
                                                    iAmTheLeaderAbstract := iAmTheLeaderWrite6;
                                                    terms := termWrite5;
                                                    lastSeen := lastmsgWrite2;
                                                    nexts := nextChanWrite7;
                                                    logs := logChanWrite6;
                                                    commits := commitChanWrite6;
                                                    goto ProcessMsgs;
                                                };
                                            } else {
                                                iAmTheLeaderWrite2 := iAmTheLeaderAbstract;
                                                termWrite1 := terms;
                                                logChanWrite2 := logs;
                                                commitChanWrite2 := commits;
                                                nextChanWrite3 := nexts;
                                                iAmTheLeaderWrite3 := iAmTheLeaderWrite2;
                                                termWrite2 := termWrite1;
                                                logChanWrite3 := logChanWrite2;
                                                commitChanWrite3 := commitChanWrite2;
                                                nextChanWrite4 := nextChanWrite3;
                                                nextChanWrite5 := nextChanWrite4;
                                                networkWrite6 := mailboxes;
                                                iAmTheLeaderWrite4 := iAmTheLeaderWrite3;
                                                termWrite3 := termWrite2;
                                                logChanWrite4 := logChanWrite3;
                                                commitChanWrite4 := commitChanWrite3;
                                                networkWrite7 := networkWrite6;
                                                nextChanWrite6 := nextChanWrite5;
                                                iAmTheLeaderWrite5 := iAmTheLeaderWrite4;
                                                termWrite4 := termWrite3;
                                                logChanWrite5 := logChanWrite4;
                                                commitChanWrite5 := commitChanWrite4;
                                                lastmsgWrite2 := lastSeen;
                                                networkWrite8 := networkWrite7;
                                                appliedWrite4 := learnedChan;
                                                nextChanWrite7 := nextChanWrite6;
                                                iAmTheLeaderWrite6 := iAmTheLeaderWrite5;
                                                termWrite5 := termWrite4;
                                                logChanWrite6 := logChanWrite5;
                                                commitChanWrite6 := commitChanWrite5;
                                                mailboxes := networkWrite8;
                                                learnedChan := appliedWrite4;
                                                iAmTheLeaderAbstract := iAmTheLeaderWrite6;
                                                terms := termWrite5;
                                                lastSeen := lastmsgWrite2;
                                                nexts := nextChanWrite7;
                                                logs := logChanWrite6;
                                                commits := commitChanWrite6;
                                                goto ProcessMsgs;
                                            };
                                        } else {
                                            iAmTheLeaderWrite3 := iAmTheLeaderAbstract;
                                            termWrite2 := terms;
                                            logChanWrite3 := logs;
                                            commitChanWrite3 := commits;
                                            nextChanWrite4 := nexts;
                                            nextChanWrite5 := nextChanWrite4;
                                            networkWrite6 := mailboxes;
                                            iAmTheLeaderWrite4 := iAmTheLeaderWrite3;
                                            termWrite3 := termWrite2;
                                            logChanWrite4 := logChanWrite3;
                                            commitChanWrite4 := commitChanWrite3;
                                            networkWrite7 := networkWrite6;
                                            nextChanWrite6 := nextChanWrite5;
                                            iAmTheLeaderWrite5 := iAmTheLeaderWrite4;
                                            termWrite4 := termWrite3;
                                            logChanWrite5 := logChanWrite4;
                                            commitChanWrite5 := commitChanWrite4;
                                            lastmsgWrite2 := lastSeen;
                                            networkWrite8 := networkWrite7;
                                            appliedWrite4 := learnedChan;
                                            nextChanWrite7 := nextChanWrite6;
                                            iAmTheLeaderWrite6 := iAmTheLeaderWrite5;
                                            termWrite5 := termWrite4;
                                            logChanWrite6 := logChanWrite5;
                                            commitChanWrite6 := commitChanWrite5;
                                            mailboxes := networkWrite8;
                                            learnedChan := appliedWrite4;
                                            iAmTheLeaderAbstract := iAmTheLeaderWrite6;
                                            terms := termWrite5;
                                            lastSeen := lastmsgWrite2;
                                            nexts := nextChanWrite7;
                                            logs := logChanWrite6;
                                            commits := commitChanWrite6;
                                            goto ProcessMsgs;
                                        };
                                    };
                                };
                            };
                    
                    } else {
                        iAmTheLeaderWrite7 := iAmTheLeaderAbstract;
                        lastmsgWrite3 := lastSeen;
                        networkWrite9 := mailboxes;
                        appliedWrite5 := learnedChan;
                        nextChanWrite8 := nexts;
                        termWrite6 := terms;
                        logChanWrite7 := logs;
                        commitChanWrite7 := commits;
                        mailboxes := networkWrite9;
                        learnedChan := appliedWrite5;
                        iAmTheLeaderAbstract := iAmTheLeaderWrite7;
                        terms := termWrite6;
                        lastSeen := lastmsgWrite3;
                        nexts := nextChanWrite8;
                        logs := logChanWrite7;
                        commits := commitChanWrite7;
                        goto NodeLoop;
                    };
            
            } else {
                networkWrite10 := mailboxes;
                inputWrite1 := values;
                logChanWrite8 := logs;
                nextChanWrite9 := nexts;
                commitChanWrite8 := commits;
                appliedWrite6 := learnedChan;
                iAmTheLeaderWrite8 := iAmTheLeaderAbstract;
                lastmsgWrite4 := lastSeen;
                termWrite7 := terms;
                mailboxes := networkWrite10;
                learnedChan := appliedWrite6;
                values := inputWrite1;
                iAmTheLeaderAbstract := iAmTheLeaderWrite8;
                terms := termWrite7;
                lastSeen := lastmsgWrite4;
                nexts := nextChanWrite9;
                logs := logChanWrite8;
                commits := commitChanWrite8;
            };
    
    }
    fair process (heartbeat \in Heartbeats)
    variables index, next = [s \in Servers |-> NULL];
    {
        HBLoop:
            if (TRUE) {
                CheckHeartBeat:
                    iAmTheLeaderRead0 := iAmTheLeaderAbstract[self];
                    await iAmTheLeaderRead0;
                
                SendHeartBeatLoop:
                    iAmTheLeaderRead0 := iAmTheLeaderAbstract[self];
                    if (iAmTheLeaderRead0) {
                        timerWrite := HeartBeatFrequency;
                        index := 0;
                        nextIndexInRead := nexts[(self) - (NUM_NODES)];
                        next := nextIndexInRead;
                        frequency := timerWrite;
                        SendHeartBeats:
                            if ((index) < (NUM_NODES)) {
                                if ((index) # ((self) - (NUM_NODES))) {
                                    termRead := terms[(self) - (NUM_NODES)];
                                    logInRead := logs[(self) - (NUM_NODES)];
                                    logInRead0 := logs[(self) - (NUM_NODES)];
                                    logInRead1 := logs[(self) - (NUM_NODES)];
                                    commitInRead := commits[(self) - (NUM_NODES)];
                                    networkWrite11 := [mailboxes EXCEPT ![index] = Append(mailboxes[index], [sender |-> (self) - (NUM_NODES), type |-> AppendEntries, term |-> termRead, granted |-> FALSE, entries |-> SubSeq(logInRead, next[index], Len(logInRead0)), prevIndex |-> (next[index]) - (1), prevTerm |-> Term(logInRead1, (next[index]) - (1)), commit |-> commitInRead])];
                                    networkWrite12 := networkWrite11;
                                } else {
                                    networkWrite12 := mailboxes;
                                };
                                index := (index) + (1);
                                networkWrite13 := networkWrite12;
                                mailboxes := networkWrite13;
                                goto SendHeartBeats;
                            } else {
                                networkWrite13 := mailboxes;
                                mailboxes := networkWrite13;
                                goto SendHeartBeatLoop;
                            };
                    
                    } else {
                        timerWrite0 := frequency;
                        networkWrite14 := mailboxes;
                        mailboxes := networkWrite14;
                        frequency := timerWrite0;
                        goto HBLoop;
                    };
            
            } else {
                timerWrite1 := frequency;
                networkWrite15 := mailboxes;
                mailboxes := networkWrite15;
                frequency := timerWrite1;
            };
    
    }
}
\* END PLUSCAL TRANSLATION

******************************************************************************)

\* BEGIN TRANSLATION
\* Process variable msg of process kvRequests at line 491 col 15 changed to msg_
\* Process variable result of process kvRequests at line 491 col 85 changed to result_
CONSTANT defaultInitValue
VARIABLES values, requestSet, learnedChan, raftLayerChan, kvClient, 
          idAbstract, database, iAmTheLeaderAbstract, frequency, terms, 
          lastSeen, nexts, logs, commits, mailboxes, requestsRead, 
          requestsWrite, iAmTheLeaderRead, proposerChanWrite, raftChanRead, 
          raftChanWrite, upstreamWrite, proposerChanWrite0, raftChanWrite0, 
          upstreamWrite0, requestsWrite0, proposerChanWrite1, raftChanWrite1, 
          upstreamWrite1, learnerChanRead, learnerChanWrite, kvIdRead, 
          dbWrite, dbWrite0, kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
          requestServiceWrite, requestServiceWrite0, learnerChanWrite0, 
          dbWrite1, requestServiceWrite1, timeoutRead, networkWrite, 
          networkWrite0, networkWrite1, inputRead, inputWrite, logChanWrite, 
          nextChanWrite, commitChanWrite, appliedWrite, appliedWrite0, 
          networkWrite2, networkWrite3, inputWrite0, logChanWrite0, 
          nextChanWrite0, commitChanWrite0, appliedWrite1, networkWrite4, 
          networkRead, iAmTheLeaderWrite, iAmTheLeaderWrite0, lastmsgWrite, 
          lastmsgWrite0, lastmsgWrite1, ifResult, appliedWrite2, 
          appliedWrite3, ifResult0, nextChanWrite1, networkWrite5, termWrite, 
          iAmTheLeaderWrite1, termWrite0, logChanWrite1, commitChanWrite1, 
          nextChanWrite2, iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
          commitChanWrite2, nextChanWrite3, iAmTheLeaderWrite3, termWrite2, 
          logChanWrite3, commitChanWrite3, nextChanWrite4, nextChanWrite5, 
          networkWrite6, iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
          commitChanWrite4, networkWrite7, nextChanWrite6, iAmTheLeaderWrite5, 
          termWrite4, logChanWrite5, commitChanWrite5, lastmsgWrite2, 
          networkWrite8, appliedWrite4, nextChanWrite7, iAmTheLeaderWrite6, 
          termWrite5, logChanWrite6, commitChanWrite6, iAmTheLeaderWrite7, 
          lastmsgWrite3, networkWrite9, appliedWrite5, nextChanWrite8, 
          termWrite6, logChanWrite7, commitChanWrite7, networkWrite10, 
          inputWrite1, logChanWrite8, nextChanWrite9, commitChanWrite8, 
          appliedWrite6, iAmTheLeaderWrite8, lastmsgWrite4, termWrite7, 
          iAmTheLeaderRead0, timerWrite, nextIndexInRead, termRead, logInRead, 
          logInRead0, logInRead1, commitInRead, networkWrite11, 
          networkWrite12, networkWrite13, timerWrite0, networkWrite14, 
          timerWrite1, networkWrite15, pc

(* define statement *)
RequestVote == 0
RequestVoteResponse == 1
AppendEntries == 2
AppendEntriesResponse == 3
Servers == (0) .. ((NUM_NODES) - (1))
Heartbeats == (NUM_NODES) .. (((NUM_NODES) * (2)) - (1))
KVRequests == ((2) * (NUM_NODES)) .. (((3) * (NUM_NODES)) - (1))
KVManager == ((3) * (NUM_NODES)) .. (((4) * (NUM_NODES)) - (1))
GET_MSG == 4
PUT_MSG == 5
GET_RESPONSE_MSG == 6
NOT_LEADER_MSG == 7
OK_MSG == 8
GET == 9
PUT == 10
Term(log, index) == IF (((index) > (0)) /\ ((Len(log)) >= (index))) /\ ((Len(log)) > (0)) THEN (log[index]).term ELSE 0

VARIABLES msg_, null, heartbeatId, proposerId, counter, requestId, proposal, 
          result_, result, learnerId, decided, timeoutLocal, currentTerm, 
          votedFor, log, state, commitIndex, lastApplied, nextIndex, 
          matchIndex, iterator, votes, value, msg, response, msgs, index, 
          next

vars == << values, requestSet, learnedChan, raftLayerChan, kvClient, 
           idAbstract, database, iAmTheLeaderAbstract, frequency, terms, 
           lastSeen, nexts, logs, commits, mailboxes, requestsRead, 
           requestsWrite, iAmTheLeaderRead, proposerChanWrite, raftChanRead, 
           raftChanWrite, upstreamWrite, proposerChanWrite0, raftChanWrite0, 
           upstreamWrite0, requestsWrite0, proposerChanWrite1, raftChanWrite1, 
           upstreamWrite1, learnerChanRead, learnerChanWrite, kvIdRead, 
           dbWrite, dbWrite0, kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
           requestServiceWrite, requestServiceWrite0, learnerChanWrite0, 
           dbWrite1, requestServiceWrite1, timeoutRead, networkWrite, 
           networkWrite0, networkWrite1, inputRead, inputWrite, logChanWrite, 
           nextChanWrite, commitChanWrite, appliedWrite, appliedWrite0, 
           networkWrite2, networkWrite3, inputWrite0, logChanWrite0, 
           nextChanWrite0, commitChanWrite0, appliedWrite1, networkWrite4, 
           networkRead, iAmTheLeaderWrite, iAmTheLeaderWrite0, lastmsgWrite, 
           lastmsgWrite0, lastmsgWrite1, ifResult, appliedWrite2, 
           appliedWrite3, ifResult0, nextChanWrite1, networkWrite5, termWrite, 
           iAmTheLeaderWrite1, termWrite0, logChanWrite1, commitChanWrite1, 
           nextChanWrite2, iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
           commitChanWrite2, nextChanWrite3, iAmTheLeaderWrite3, termWrite2, 
           logChanWrite3, commitChanWrite3, nextChanWrite4, nextChanWrite5, 
           networkWrite6, iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
           commitChanWrite4, networkWrite7, nextChanWrite6, 
           iAmTheLeaderWrite5, termWrite4, logChanWrite5, commitChanWrite5, 
           lastmsgWrite2, networkWrite8, appliedWrite4, nextChanWrite7, 
           iAmTheLeaderWrite6, termWrite5, logChanWrite6, commitChanWrite6, 
           iAmTheLeaderWrite7, lastmsgWrite3, networkWrite9, appliedWrite5, 
           nextChanWrite8, termWrite6, logChanWrite7, commitChanWrite7, 
           networkWrite10, inputWrite1, logChanWrite8, nextChanWrite9, 
           commitChanWrite8, appliedWrite6, iAmTheLeaderWrite8, lastmsgWrite4, 
           termWrite7, iAmTheLeaderRead0, timerWrite, nextIndexInRead, 
           termRead, logInRead, logInRead0, logInRead1, commitInRead, 
           networkWrite11, networkWrite12, networkWrite13, timerWrite0, 
           networkWrite14, timerWrite1, networkWrite15, pc, msg_, null, 
           heartbeatId, proposerId, counter, requestId, proposal, result_, 
           result, learnerId, decided, timeoutLocal, currentTerm, votedFor, 
           log, state, commitIndex, lastApplied, nextIndex, matchIndex, 
           iterator, votes, value, msg, response, msgs, index, next >>

ProcSet == (KVRequests) \cup (KVManager) \cup (Servers) \cup (Heartbeats)

Init == (* Global variables *)
        /\ values = [k \in Servers |-> <<>>]
        /\ requestSet = (({[type |-> GET_MSG, key |-> k, value |-> NULL] : k \in GetSet}) \union ({[type |-> PUT_MSG, key |-> v, value |-> v] : v \in PutSet}))
        /\ learnedChan = [l \in Servers |-> <<>>]
        /\ raftLayerChan = [p \in KVRequests |-> <<>>]
        /\ kvClient = {}
        /\ idAbstract = defaultInitValue
        /\ database = [p \in KVRequests, k \in (GetSet) \union (PutSet) |-> NULL_DB_VALUE]
        /\ iAmTheLeaderAbstract = [h \in Heartbeats |-> FALSE]
        /\ frequency = 500
        /\ terms = [s \in Servers |-> NULL]
        /\ lastSeen = defaultInitValue
        /\ nexts = [x \in Servers |-> [s \in Servers |-> NULL]]
        /\ logs = [s \in Servers |-> NULL]
        /\ commits = [s \in Servers |-> NULL]
        /\ mailboxes = [id \in Servers |-> <<>>]
        /\ requestsRead = defaultInitValue
        /\ requestsWrite = defaultInitValue
        /\ iAmTheLeaderRead = defaultInitValue
        /\ proposerChanWrite = defaultInitValue
        /\ raftChanRead = defaultInitValue
        /\ raftChanWrite = defaultInitValue
        /\ upstreamWrite = defaultInitValue
        /\ proposerChanWrite0 = defaultInitValue
        /\ raftChanWrite0 = defaultInitValue
        /\ upstreamWrite0 = defaultInitValue
        /\ requestsWrite0 = defaultInitValue
        /\ proposerChanWrite1 = defaultInitValue
        /\ raftChanWrite1 = defaultInitValue
        /\ upstreamWrite1 = defaultInitValue
        /\ learnerChanRead = defaultInitValue
        /\ learnerChanWrite = defaultInitValue
        /\ kvIdRead = defaultInitValue
        /\ dbWrite = defaultInitValue
        /\ dbWrite0 = defaultInitValue
        /\ kvIdRead0 = defaultInitValue
        /\ kvIdRead1 = defaultInitValue
        /\ dbRead = defaultInitValue
        /\ kvIdRead2 = defaultInitValue
        /\ requestServiceWrite = defaultInitValue
        /\ requestServiceWrite0 = defaultInitValue
        /\ learnerChanWrite0 = defaultInitValue
        /\ dbWrite1 = defaultInitValue
        /\ requestServiceWrite1 = defaultInitValue
        /\ timeoutRead = defaultInitValue
        /\ networkWrite = defaultInitValue
        /\ networkWrite0 = defaultInitValue
        /\ networkWrite1 = defaultInitValue
        /\ inputRead = defaultInitValue
        /\ inputWrite = defaultInitValue
        /\ logChanWrite = defaultInitValue
        /\ nextChanWrite = defaultInitValue
        /\ commitChanWrite = defaultInitValue
        /\ appliedWrite = defaultInitValue
        /\ appliedWrite0 = defaultInitValue
        /\ networkWrite2 = defaultInitValue
        /\ networkWrite3 = defaultInitValue
        /\ inputWrite0 = defaultInitValue
        /\ logChanWrite0 = defaultInitValue
        /\ nextChanWrite0 = defaultInitValue
        /\ commitChanWrite0 = defaultInitValue
        /\ appliedWrite1 = defaultInitValue
        /\ networkWrite4 = defaultInitValue
        /\ networkRead = defaultInitValue
        /\ iAmTheLeaderWrite = defaultInitValue
        /\ iAmTheLeaderWrite0 = defaultInitValue
        /\ lastmsgWrite = defaultInitValue
        /\ lastmsgWrite0 = defaultInitValue
        /\ lastmsgWrite1 = defaultInitValue
        /\ ifResult = defaultInitValue
        /\ appliedWrite2 = defaultInitValue
        /\ appliedWrite3 = defaultInitValue
        /\ ifResult0 = defaultInitValue
        /\ nextChanWrite1 = defaultInitValue
        /\ networkWrite5 = defaultInitValue
        /\ termWrite = defaultInitValue
        /\ iAmTheLeaderWrite1 = defaultInitValue
        /\ termWrite0 = defaultInitValue
        /\ logChanWrite1 = defaultInitValue
        /\ commitChanWrite1 = defaultInitValue
        /\ nextChanWrite2 = defaultInitValue
        /\ iAmTheLeaderWrite2 = defaultInitValue
        /\ termWrite1 = defaultInitValue
        /\ logChanWrite2 = defaultInitValue
        /\ commitChanWrite2 = defaultInitValue
        /\ nextChanWrite3 = defaultInitValue
        /\ iAmTheLeaderWrite3 = defaultInitValue
        /\ termWrite2 = defaultInitValue
        /\ logChanWrite3 = defaultInitValue
        /\ commitChanWrite3 = defaultInitValue
        /\ nextChanWrite4 = defaultInitValue
        /\ nextChanWrite5 = defaultInitValue
        /\ networkWrite6 = defaultInitValue
        /\ iAmTheLeaderWrite4 = defaultInitValue
        /\ termWrite3 = defaultInitValue
        /\ logChanWrite4 = defaultInitValue
        /\ commitChanWrite4 = defaultInitValue
        /\ networkWrite7 = defaultInitValue
        /\ nextChanWrite6 = defaultInitValue
        /\ iAmTheLeaderWrite5 = defaultInitValue
        /\ termWrite4 = defaultInitValue
        /\ logChanWrite5 = defaultInitValue
        /\ commitChanWrite5 = defaultInitValue
        /\ lastmsgWrite2 = defaultInitValue
        /\ networkWrite8 = defaultInitValue
        /\ appliedWrite4 = defaultInitValue
        /\ nextChanWrite7 = defaultInitValue
        /\ iAmTheLeaderWrite6 = defaultInitValue
        /\ termWrite5 = defaultInitValue
        /\ logChanWrite6 = defaultInitValue
        /\ commitChanWrite6 = defaultInitValue
        /\ iAmTheLeaderWrite7 = defaultInitValue
        /\ lastmsgWrite3 = defaultInitValue
        /\ networkWrite9 = defaultInitValue
        /\ appliedWrite5 = defaultInitValue
        /\ nextChanWrite8 = defaultInitValue
        /\ termWrite6 = defaultInitValue
        /\ logChanWrite7 = defaultInitValue
        /\ commitChanWrite7 = defaultInitValue
        /\ networkWrite10 = defaultInitValue
        /\ inputWrite1 = defaultInitValue
        /\ logChanWrite8 = defaultInitValue
        /\ nextChanWrite9 = defaultInitValue
        /\ commitChanWrite8 = defaultInitValue
        /\ appliedWrite6 = defaultInitValue
        /\ iAmTheLeaderWrite8 = defaultInitValue
        /\ lastmsgWrite4 = defaultInitValue
        /\ termWrite7 = defaultInitValue
        /\ iAmTheLeaderRead0 = defaultInitValue
        /\ timerWrite = defaultInitValue
        /\ nextIndexInRead = defaultInitValue
        /\ termRead = defaultInitValue
        /\ logInRead = defaultInitValue
        /\ logInRead0 = defaultInitValue
        /\ logInRead1 = defaultInitValue
        /\ commitInRead = defaultInitValue
        /\ networkWrite11 = defaultInitValue
        /\ networkWrite12 = defaultInitValue
        /\ networkWrite13 = defaultInitValue
        /\ timerWrite0 = defaultInitValue
        /\ networkWrite14 = defaultInitValue
        /\ timerWrite1 = defaultInitValue
        /\ networkWrite15 = defaultInitValue
        (* Process kvRequests *)
        /\ msg_ = [self \in KVRequests |-> defaultInitValue]
        /\ null = [self \in KVRequests |-> defaultInitValue]
        /\ heartbeatId = [self \in KVRequests |-> defaultInitValue]
        /\ proposerId = [self \in KVRequests |-> defaultInitValue]
        /\ counter = [self \in KVRequests |-> 0]
        /\ requestId = [self \in KVRequests |-> defaultInitValue]
        /\ proposal = [self \in KVRequests |-> defaultInitValue]
        /\ result_ = [self \in KVRequests |-> defaultInitValue]
        (* Process kvManager *)
        /\ result = [self \in KVManager |-> defaultInitValue]
        /\ learnerId = [self \in KVManager |-> defaultInitValue]
        /\ decided = [self \in KVManager |-> defaultInitValue]
        (* Process server *)
        /\ timeoutLocal = [self \in Servers |-> TRUE]
        /\ currentTerm = [self \in Servers |-> 0]
        /\ votedFor = [self \in Servers |-> NULL]
        /\ log = [self \in Servers |-> <<>>]
        /\ state = [self \in Servers |-> Follower]
        /\ commitIndex = [self \in Servers |-> 0]
        /\ lastApplied = [self \in Servers |-> 0]
        /\ nextIndex = [self \in Servers |-> defaultInitValue]
        /\ matchIndex = [self \in Servers |-> defaultInitValue]
        /\ iterator = [self \in Servers |-> defaultInitValue]
        /\ votes = [self \in Servers |-> [t \in (0) .. (Terms) |-> {}]]
        /\ value = [self \in Servers |-> defaultInitValue]
        /\ msg = [self \in Servers |-> defaultInitValue]
        /\ response = [self \in Servers |-> defaultInitValue]
        /\ msgs = [self \in Servers |-> defaultInitValue]
        (* Process heartbeat *)
        /\ index = [self \in Heartbeats |-> defaultInitValue]
        /\ next = [self \in Heartbeats |-> [s \in Servers |-> NULL]]
        /\ pc = [self \in ProcSet |-> CASE self \in KVRequests -> "kvInit"
                                        [] self \in KVManager -> "findId"
                                        [] self \in Servers -> "NodeLoop"
                                        [] self \in Heartbeats -> "HBLoop"]

kvInit(self) == /\ pc[self] = "kvInit"
                /\ heartbeatId' = [heartbeatId EXCEPT ![self] = (self) - (NUM_NODES)]
                /\ proposerId' = [proposerId EXCEPT ![self] = (self) - ((2) * (NUM_NODES))]
                /\ pc' = [pc EXCEPT ![self] = "kvLoop"]
                /\ UNCHANGED << values, requestSet, learnedChan, raftLayerChan, 
                                kvClient, idAbstract, database, 
                                iAmTheLeaderAbstract, frequency, terms, 
                                lastSeen, nexts, logs, commits, mailboxes, 
                                requestsRead, requestsWrite, iAmTheLeaderRead, 
                                proposerChanWrite, raftChanRead, raftChanWrite, 
                                upstreamWrite, proposerChanWrite0, 
                                raftChanWrite0, upstreamWrite0, requestsWrite0, 
                                proposerChanWrite1, raftChanWrite1, 
                                upstreamWrite1, learnerChanRead, 
                                learnerChanWrite, kvIdRead, dbWrite, dbWrite0, 
                                kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
                                requestServiceWrite, requestServiceWrite0, 
                                learnerChanWrite0, dbWrite1, 
                                requestServiceWrite1, timeoutRead, 
                                networkWrite, networkWrite0, networkWrite1, 
                                inputRead, inputWrite, logChanWrite, 
                                nextChanWrite, commitChanWrite, appliedWrite, 
                                appliedWrite0, networkWrite2, networkWrite3, 
                                inputWrite0, logChanWrite0, nextChanWrite0, 
                                commitChanWrite0, appliedWrite1, networkWrite4, 
                                networkRead, iAmTheLeaderWrite, 
                                iAmTheLeaderWrite0, lastmsgWrite, 
                                lastmsgWrite0, lastmsgWrite1, ifResult, 
                                appliedWrite2, appliedWrite3, ifResult0, 
                                nextChanWrite1, networkWrite5, termWrite, 
                                iAmTheLeaderWrite1, termWrite0, logChanWrite1, 
                                commitChanWrite1, nextChanWrite2, 
                                iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
                                commitChanWrite2, nextChanWrite3, 
                                iAmTheLeaderWrite3, termWrite2, logChanWrite3, 
                                commitChanWrite3, nextChanWrite4, 
                                nextChanWrite5, networkWrite6, 
                                iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
                                commitChanWrite4, networkWrite7, 
                                nextChanWrite6, iAmTheLeaderWrite5, termWrite4, 
                                logChanWrite5, commitChanWrite5, lastmsgWrite2, 
                                networkWrite8, appliedWrite4, nextChanWrite7, 
                                iAmTheLeaderWrite6, termWrite5, logChanWrite6, 
                                commitChanWrite6, iAmTheLeaderWrite7, 
                                lastmsgWrite3, networkWrite9, appliedWrite5, 
                                nextChanWrite8, termWrite6, logChanWrite7, 
                                commitChanWrite7, networkWrite10, inputWrite1, 
                                logChanWrite8, nextChanWrite9, 
                                commitChanWrite8, appliedWrite6, 
                                iAmTheLeaderWrite8, lastmsgWrite4, termWrite7, 
                                iAmTheLeaderRead0, timerWrite, nextIndexInRead, 
                                termRead, logInRead, logInRead0, logInRead1, 
                                commitInRead, networkWrite11, networkWrite12, 
                                networkWrite13, timerWrite0, networkWrite14, 
                                timerWrite1, networkWrite15, msg_, null, 
                                counter, requestId, proposal, result_, result, 
                                learnerId, decided, timeoutLocal, currentTerm, 
                                votedFor, log, state, commitIndex, lastApplied, 
                                nextIndex, matchIndex, iterator, votes, value, 
                                msg, response, msgs, index, next >>

kvLoop(self) == /\ pc[self] = "kvLoop"
                /\ IF TRUE
                      THEN /\ (Cardinality(requestSet)) > (0)
                           /\ \E req0 \in requestSet:
                                /\ requestsWrite' = (requestSet) \ ({req0})
                                /\ requestsRead' = req0
                           /\ msg_' = [msg_ EXCEPT ![self] = requestsRead']
                           /\ Assert((((msg_'[self]).type) = (GET_MSG)) \/ (((msg_'[self]).type) = (PUT_MSG)), 
                                     "Failure of assertion at line 504, column 17.")
                           /\ iAmTheLeaderRead' = iAmTheLeaderAbstract[heartbeatId[self]]
                           /\ IF iAmTheLeaderRead'
                                 THEN /\ requestId' = [requestId EXCEPT ![self] = <<self, counter[self]>>]
                                      /\ IF ((msg_'[self]).type) = (GET_MSG)
                                            THEN /\ proposal' = [proposal EXCEPT ![self] = [operation |-> GET, id |-> requestId'[self], key |-> (msg_'[self]).key, value |-> (msg_'[self]).key]]
                                            ELSE /\ proposal' = [proposal EXCEPT ![self] = [operation |-> PUT, id |-> requestId'[self], key |-> (msg_'[self]).key, value |-> (msg_'[self]).value]]
                                      /\ (Len(values[proposerId[self]])) < (BUFFER_SIZE)
                                      /\ proposerChanWrite' = [values EXCEPT ![proposerId[self]] = Append(values[proposerId[self]], proposal'[self])]
                                      /\ (Len(raftLayerChan[self])) > (0)
                                      /\ LET msg0 == Head(raftLayerChan[self]) IN
                                           /\ raftChanWrite' = [raftLayerChan EXCEPT ![self] = Tail(raftLayerChan[self])]
                                           /\ raftChanRead' = msg0
                                      /\ result_' = [result_ EXCEPT ![self] = raftChanRead']
                                      /\ upstreamWrite' = ((kvClient) \union ({[type |-> OK_MSG, result |-> result_'[self]]}))
                                      /\ counter' = [counter EXCEPT ![self] = (counter[self]) + (1)]
                                      /\ proposerChanWrite0' = proposerChanWrite'
                                      /\ raftChanWrite0' = raftChanWrite'
                                      /\ upstreamWrite0' = upstreamWrite'
                                      /\ requestsWrite0' = requestsWrite'
                                      /\ proposerChanWrite1' = proposerChanWrite0'
                                      /\ raftChanWrite1' = raftChanWrite0'
                                      /\ upstreamWrite1' = upstreamWrite0'
                                      /\ requestSet' = requestsWrite0'
                                      /\ kvClient' = upstreamWrite1'
                                      /\ values' = proposerChanWrite1'
                                      /\ raftLayerChan' = raftChanWrite1'
                                      /\ pc' = [pc EXCEPT ![self] = "kvLoop"]
                                 ELSE /\ upstreamWrite' = ((kvClient) \union ({[type |-> NOT_LEADER_MSG, result |-> null[self]]}))
                                      /\ proposerChanWrite0' = values
                                      /\ raftChanWrite0' = raftLayerChan
                                      /\ upstreamWrite0' = upstreamWrite'
                                      /\ requestsWrite0' = requestsWrite'
                                      /\ proposerChanWrite1' = proposerChanWrite0'
                                      /\ raftChanWrite1' = raftChanWrite0'
                                      /\ upstreamWrite1' = upstreamWrite0'
                                      /\ requestSet' = requestsWrite0'
                                      /\ kvClient' = upstreamWrite1'
                                      /\ values' = proposerChanWrite1'
                                      /\ raftLayerChan' = raftChanWrite1'
                                      /\ pc' = [pc EXCEPT ![self] = "kvLoop"]
                                      /\ UNCHANGED << proposerChanWrite, 
                                                      raftChanRead, 
                                                      raftChanWrite, counter, 
                                                      requestId, proposal, 
                                                      result_ >>
                      ELSE /\ requestsWrite0' = requestSet
                           /\ proposerChanWrite1' = values
                           /\ raftChanWrite1' = raftLayerChan
                           /\ upstreamWrite1' = kvClient
                           /\ requestSet' = requestsWrite0'
                           /\ kvClient' = upstreamWrite1'
                           /\ values' = proposerChanWrite1'
                           /\ raftLayerChan' = raftChanWrite1'
                           /\ pc' = [pc EXCEPT ![self] = "Done"]
                           /\ UNCHANGED << requestsRead, requestsWrite, 
                                           iAmTheLeaderRead, proposerChanWrite, 
                                           raftChanRead, raftChanWrite, 
                                           upstreamWrite, proposerChanWrite0, 
                                           raftChanWrite0, upstreamWrite0, 
                                           msg_, counter, requestId, proposal, 
                                           result_ >>
                /\ UNCHANGED << learnedChan, idAbstract, database, 
                                iAmTheLeaderAbstract, frequency, terms, 
                                lastSeen, nexts, logs, commits, mailboxes, 
                                learnerChanRead, learnerChanWrite, kvIdRead, 
                                dbWrite, dbWrite0, kvIdRead0, kvIdRead1, 
                                dbRead, kvIdRead2, requestServiceWrite, 
                                requestServiceWrite0, learnerChanWrite0, 
                                dbWrite1, requestServiceWrite1, timeoutRead, 
                                networkWrite, networkWrite0, networkWrite1, 
                                inputRead, inputWrite, logChanWrite, 
                                nextChanWrite, commitChanWrite, appliedWrite, 
                                appliedWrite0, networkWrite2, networkWrite3, 
                                inputWrite0, logChanWrite0, nextChanWrite0, 
                                commitChanWrite0, appliedWrite1, networkWrite4, 
                                networkRead, iAmTheLeaderWrite, 
                                iAmTheLeaderWrite0, lastmsgWrite, 
                                lastmsgWrite0, lastmsgWrite1, ifResult, 
                                appliedWrite2, appliedWrite3, ifResult0, 
                                nextChanWrite1, networkWrite5, termWrite, 
                                iAmTheLeaderWrite1, termWrite0, logChanWrite1, 
                                commitChanWrite1, nextChanWrite2, 
                                iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
                                commitChanWrite2, nextChanWrite3, 
                                iAmTheLeaderWrite3, termWrite2, logChanWrite3, 
                                commitChanWrite3, nextChanWrite4, 
                                nextChanWrite5, networkWrite6, 
                                iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
                                commitChanWrite4, networkWrite7, 
                                nextChanWrite6, iAmTheLeaderWrite5, termWrite4, 
                                logChanWrite5, commitChanWrite5, lastmsgWrite2, 
                                networkWrite8, appliedWrite4, nextChanWrite7, 
                                iAmTheLeaderWrite6, termWrite5, logChanWrite6, 
                                commitChanWrite6, iAmTheLeaderWrite7, 
                                lastmsgWrite3, networkWrite9, appliedWrite5, 
                                nextChanWrite8, termWrite6, logChanWrite7, 
                                commitChanWrite7, networkWrite10, inputWrite1, 
                                logChanWrite8, nextChanWrite9, 
                                commitChanWrite8, appliedWrite6, 
                                iAmTheLeaderWrite8, lastmsgWrite4, termWrite7, 
                                iAmTheLeaderRead0, timerWrite, nextIndexInRead, 
                                termRead, logInRead, logInRead0, logInRead1, 
                                commitInRead, networkWrite11, networkWrite12, 
                                networkWrite13, timerWrite0, networkWrite14, 
                                timerWrite1, networkWrite15, null, heartbeatId, 
                                proposerId, result, learnerId, decided, 
                                timeoutLocal, currentTerm, votedFor, log, 
                                state, commitIndex, lastApplied, nextIndex, 
                                matchIndex, iterator, votes, value, msg, 
                                response, msgs, index, next >>

kvRequests(self) == kvInit(self) \/ kvLoop(self)

findId(self) == /\ pc[self] = "findId"
                /\ learnerId' = [learnerId EXCEPT ![self] = (self) - ((3) * (NUM_NODES))]
                /\ pc' = [pc EXCEPT ![self] = "kvManagerLoop"]
                /\ UNCHANGED << values, requestSet, learnedChan, raftLayerChan, 
                                kvClient, idAbstract, database, 
                                iAmTheLeaderAbstract, frequency, terms, 
                                lastSeen, nexts, logs, commits, mailboxes, 
                                requestsRead, requestsWrite, iAmTheLeaderRead, 
                                proposerChanWrite, raftChanRead, raftChanWrite, 
                                upstreamWrite, proposerChanWrite0, 
                                raftChanWrite0, upstreamWrite0, requestsWrite0, 
                                proposerChanWrite1, raftChanWrite1, 
                                upstreamWrite1, learnerChanRead, 
                                learnerChanWrite, kvIdRead, dbWrite, dbWrite0, 
                                kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
                                requestServiceWrite, requestServiceWrite0, 
                                learnerChanWrite0, dbWrite1, 
                                requestServiceWrite1, timeoutRead, 
                                networkWrite, networkWrite0, networkWrite1, 
                                inputRead, inputWrite, logChanWrite, 
                                nextChanWrite, commitChanWrite, appliedWrite, 
                                appliedWrite0, networkWrite2, networkWrite3, 
                                inputWrite0, logChanWrite0, nextChanWrite0, 
                                commitChanWrite0, appliedWrite1, networkWrite4, 
                                networkRead, iAmTheLeaderWrite, 
                                iAmTheLeaderWrite0, lastmsgWrite, 
                                lastmsgWrite0, lastmsgWrite1, ifResult, 
                                appliedWrite2, appliedWrite3, ifResult0, 
                                nextChanWrite1, networkWrite5, termWrite, 
                                iAmTheLeaderWrite1, termWrite0, logChanWrite1, 
                                commitChanWrite1, nextChanWrite2, 
                                iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
                                commitChanWrite2, nextChanWrite3, 
                                iAmTheLeaderWrite3, termWrite2, logChanWrite3, 
                                commitChanWrite3, nextChanWrite4, 
                                nextChanWrite5, networkWrite6, 
                                iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
                                commitChanWrite4, networkWrite7, 
                                nextChanWrite6, iAmTheLeaderWrite5, termWrite4, 
                                logChanWrite5, commitChanWrite5, lastmsgWrite2, 
                                networkWrite8, appliedWrite4, nextChanWrite7, 
                                iAmTheLeaderWrite6, termWrite5, logChanWrite6, 
                                commitChanWrite6, iAmTheLeaderWrite7, 
                                lastmsgWrite3, networkWrite9, appliedWrite5, 
                                nextChanWrite8, termWrite6, logChanWrite7, 
                                commitChanWrite7, networkWrite10, inputWrite1, 
                                logChanWrite8, nextChanWrite9, 
                                commitChanWrite8, appliedWrite6, 
                                iAmTheLeaderWrite8, lastmsgWrite4, termWrite7, 
                                iAmTheLeaderRead0, timerWrite, nextIndexInRead, 
                                termRead, logInRead, logInRead0, logInRead1, 
                                commitInRead, networkWrite11, networkWrite12, 
                                networkWrite13, timerWrite0, networkWrite14, 
                                timerWrite1, networkWrite15, msg_, null, 
                                heartbeatId, proposerId, counter, requestId, 
                                proposal, result_, result, decided, 
                                timeoutLocal, currentTerm, votedFor, log, 
                                state, commitIndex, lastApplied, nextIndex, 
                                matchIndex, iterator, votes, value, msg, 
                                response, msgs, index, next >>

kvManagerLoop(self) == /\ pc[self] = "kvManagerLoop"
                       /\ IF TRUE
                             THEN /\ (Len(learnedChan[learnerId[self]])) > (0)
                                  /\ LET msg1 == Head(learnedChan[learnerId[self]]) IN
                                       /\ learnerChanWrite' = [learnedChan EXCEPT ![learnerId[self]] = Tail(learnedChan[learnerId[self]])]
                                       /\ learnerChanRead' = msg1
                                  /\ decided' = [decided EXCEPT ![self] = learnerChanRead']
                                  /\ IF ((decided'[self]).operation) = (PUT)
                                        THEN /\ kvIdRead' = (self) - (NUM_NODES)
                                             /\ dbWrite' = [database EXCEPT ![<<kvIdRead', (decided'[self]).key>>] = (decided'[self]).value]
                                             /\ dbWrite0' = dbWrite'
                                        ELSE /\ dbWrite0' = database
                                             /\ UNCHANGED << kvIdRead, dbWrite >>
                                  /\ kvIdRead0' = (self) - (NUM_NODES)
                                  /\ IF ((decided'[self]).id[1]) = (kvIdRead0')
                                        THEN /\ IF ((decided'[self]).operation) = (GET)
                                                   THEN /\ kvIdRead1' = (self) - (NUM_NODES)
                                                        /\ dbRead' = dbWrite0'[<<kvIdRead1', (decided'[self]).key>>]
                                                        /\ result' = [result EXCEPT ![self] = dbRead']
                                                   ELSE /\ result' = [result EXCEPT ![self] = (decided'[self]).value]
                                                        /\ UNCHANGED << kvIdRead1, 
                                                                        dbRead >>
                                             /\ kvIdRead2' = (self) - (NUM_NODES)
                                             /\ (Len(raftLayerChan[kvIdRead2'])) < (BUFFER_SIZE)
                                             /\ requestServiceWrite' = [raftLayerChan EXCEPT ![kvIdRead2'] = Append(raftLayerChan[kvIdRead2'], result'[self])]
                                             /\ requestServiceWrite0' = requestServiceWrite'
                                             /\ learnerChanWrite0' = learnerChanWrite'
                                             /\ dbWrite1' = dbWrite0'
                                             /\ requestServiceWrite1' = requestServiceWrite0'
                                             /\ raftLayerChan' = requestServiceWrite1'
                                             /\ learnedChan' = learnerChanWrite0'
                                             /\ database' = dbWrite1'
                                             /\ pc' = [pc EXCEPT ![self] = "kvManagerLoop"]
                                        ELSE /\ requestServiceWrite0' = raftLayerChan
                                             /\ learnerChanWrite0' = learnerChanWrite'
                                             /\ dbWrite1' = dbWrite0'
                                             /\ requestServiceWrite1' = requestServiceWrite0'
                                             /\ raftLayerChan' = requestServiceWrite1'
                                             /\ learnedChan' = learnerChanWrite0'
                                             /\ database' = dbWrite1'
                                             /\ pc' = [pc EXCEPT ![self] = "kvManagerLoop"]
                                             /\ UNCHANGED << kvIdRead1, dbRead, 
                                                             kvIdRead2, 
                                                             requestServiceWrite, 
                                                             result >>
                             ELSE /\ learnerChanWrite0' = learnedChan
                                  /\ dbWrite1' = database
                                  /\ requestServiceWrite1' = raftLayerChan
                                  /\ raftLayerChan' = requestServiceWrite1'
                                  /\ learnedChan' = learnerChanWrite0'
                                  /\ database' = dbWrite1'
                                  /\ pc' = [pc EXCEPT ![self] = "Done"]
                                  /\ UNCHANGED << learnerChanRead, 
                                                  learnerChanWrite, kvIdRead, 
                                                  dbWrite, dbWrite0, kvIdRead0, 
                                                  kvIdRead1, dbRead, kvIdRead2, 
                                                  requestServiceWrite, 
                                                  requestServiceWrite0, result, 
                                                  decided >>
                       /\ UNCHANGED << values, requestSet, kvClient, 
                                       idAbstract, iAmTheLeaderAbstract, 
                                       frequency, terms, lastSeen, nexts, logs, 
                                       commits, mailboxes, requestsRead, 
                                       requestsWrite, iAmTheLeaderRead, 
                                       proposerChanWrite, raftChanRead, 
                                       raftChanWrite, upstreamWrite, 
                                       proposerChanWrite0, raftChanWrite0, 
                                       upstreamWrite0, requestsWrite0, 
                                       proposerChanWrite1, raftChanWrite1, 
                                       upstreamWrite1, timeoutRead, 
                                       networkWrite, networkWrite0, 
                                       networkWrite1, inputRead, inputWrite, 
                                       logChanWrite, nextChanWrite, 
                                       commitChanWrite, appliedWrite, 
                                       appliedWrite0, networkWrite2, 
                                       networkWrite3, inputWrite0, 
                                       logChanWrite0, nextChanWrite0, 
                                       commitChanWrite0, appliedWrite1, 
                                       networkWrite4, networkRead, 
                                       iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                       lastmsgWrite, lastmsgWrite0, 
                                       lastmsgWrite1, ifResult, appliedWrite2, 
                                       appliedWrite3, ifResult0, 
                                       nextChanWrite1, networkWrite5, 
                                       termWrite, iAmTheLeaderWrite1, 
                                       termWrite0, logChanWrite1, 
                                       commitChanWrite1, nextChanWrite2, 
                                       iAmTheLeaderWrite2, termWrite1, 
                                       logChanWrite2, commitChanWrite2, 
                                       nextChanWrite3, iAmTheLeaderWrite3, 
                                       termWrite2, logChanWrite3, 
                                       commitChanWrite3, nextChanWrite4, 
                                       nextChanWrite5, networkWrite6, 
                                       iAmTheLeaderWrite4, termWrite3, 
                                       logChanWrite4, commitChanWrite4, 
                                       networkWrite7, nextChanWrite6, 
                                       iAmTheLeaderWrite5, termWrite4, 
                                       logChanWrite5, commitChanWrite5, 
                                       lastmsgWrite2, networkWrite8, 
                                       appliedWrite4, nextChanWrite7, 
                                       iAmTheLeaderWrite6, termWrite5, 
                                       logChanWrite6, commitChanWrite6, 
                                       iAmTheLeaderWrite7, lastmsgWrite3, 
                                       networkWrite9, appliedWrite5, 
                                       nextChanWrite8, termWrite6, 
                                       logChanWrite7, commitChanWrite7, 
                                       networkWrite10, inputWrite1, 
                                       logChanWrite8, nextChanWrite9, 
                                       commitChanWrite8, appliedWrite6, 
                                       iAmTheLeaderWrite8, lastmsgWrite4, 
                                       termWrite7, iAmTheLeaderRead0, 
                                       timerWrite, nextIndexInRead, termRead, 
                                       logInRead, logInRead0, logInRead1, 
                                       commitInRead, networkWrite11, 
                                       networkWrite12, networkWrite13, 
                                       timerWrite0, networkWrite14, 
                                       timerWrite1, networkWrite15, msg_, null, 
                                       heartbeatId, proposerId, counter, 
                                       requestId, proposal, result_, learnerId, 
                                       timeoutLocal, currentTerm, votedFor, 
                                       log, state, commitIndex, lastApplied, 
                                       nextIndex, matchIndex, iterator, votes, 
                                       value, msg, response, msgs, index, next >>

kvManager(self) == findId(self) \/ kvManagerLoop(self)

NodeLoop(self) == /\ pc[self] = "NodeLoop"
                  /\ IF TRUE
                        THEN /\ pc' = [pc EXCEPT ![self] = "TimeoutCheck"]
                             /\ UNCHANGED << values, learnedChan, 
                                             iAmTheLeaderAbstract, terms, 
                                             lastSeen, nexts, logs, commits, 
                                             mailboxes, networkWrite10, 
                                             inputWrite1, logChanWrite8, 
                                             nextChanWrite9, commitChanWrite8, 
                                             appliedWrite6, iAmTheLeaderWrite8, 
                                             lastmsgWrite4, termWrite7 >>
                        ELSE /\ networkWrite10' = mailboxes
                             /\ inputWrite1' = values
                             /\ logChanWrite8' = logs
                             /\ nextChanWrite9' = nexts
                             /\ commitChanWrite8' = commits
                             /\ appliedWrite6' = learnedChan
                             /\ iAmTheLeaderWrite8' = iAmTheLeaderAbstract
                             /\ lastmsgWrite4' = lastSeen
                             /\ termWrite7' = terms
                             /\ mailboxes' = networkWrite10'
                             /\ learnedChan' = appliedWrite6'
                             /\ values' = inputWrite1'
                             /\ iAmTheLeaderAbstract' = iAmTheLeaderWrite8'
                             /\ terms' = termWrite7'
                             /\ lastSeen' = lastmsgWrite4'
                             /\ nexts' = nextChanWrite9'
                             /\ logs' = logChanWrite8'
                             /\ commits' = commitChanWrite8'
                             /\ pc' = [pc EXCEPT ![self] = "Done"]
                  /\ UNCHANGED << requestSet, raftLayerChan, kvClient, 
                                  idAbstract, database, frequency, 
                                  requestsRead, requestsWrite, 
                                  iAmTheLeaderRead, proposerChanWrite, 
                                  raftChanRead, raftChanWrite, upstreamWrite, 
                                  proposerChanWrite0, raftChanWrite0, 
                                  upstreamWrite0, requestsWrite0, 
                                  proposerChanWrite1, raftChanWrite1, 
                                  upstreamWrite1, learnerChanRead, 
                                  learnerChanWrite, kvIdRead, dbWrite, 
                                  dbWrite0, kvIdRead0, kvIdRead1, dbRead, 
                                  kvIdRead2, requestServiceWrite, 
                                  requestServiceWrite0, learnerChanWrite0, 
                                  dbWrite1, requestServiceWrite1, timeoutRead, 
                                  networkWrite, networkWrite0, networkWrite1, 
                                  inputRead, inputWrite, logChanWrite, 
                                  nextChanWrite, commitChanWrite, appliedWrite, 
                                  appliedWrite0, networkWrite2, networkWrite3, 
                                  inputWrite0, logChanWrite0, nextChanWrite0, 
                                  commitChanWrite0, appliedWrite1, 
                                  networkWrite4, networkRead, 
                                  iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                  lastmsgWrite, lastmsgWrite0, lastmsgWrite1, 
                                  ifResult, appliedWrite2, appliedWrite3, 
                                  ifResult0, nextChanWrite1, networkWrite5, 
                                  termWrite, iAmTheLeaderWrite1, termWrite0, 
                                  logChanWrite1, commitChanWrite1, 
                                  nextChanWrite2, iAmTheLeaderWrite2, 
                                  termWrite1, logChanWrite2, commitChanWrite2, 
                                  nextChanWrite3, iAmTheLeaderWrite3, 
                                  termWrite2, logChanWrite3, commitChanWrite3, 
                                  nextChanWrite4, nextChanWrite5, 
                                  networkWrite6, iAmTheLeaderWrite4, 
                                  termWrite3, logChanWrite4, commitChanWrite4, 
                                  networkWrite7, nextChanWrite6, 
                                  iAmTheLeaderWrite5, termWrite4, 
                                  logChanWrite5, commitChanWrite5, 
                                  lastmsgWrite2, networkWrite8, appliedWrite4, 
                                  nextChanWrite7, iAmTheLeaderWrite6, 
                                  termWrite5, logChanWrite6, commitChanWrite6, 
                                  iAmTheLeaderWrite7, lastmsgWrite3, 
                                  networkWrite9, appliedWrite5, nextChanWrite8, 
                                  termWrite6, logChanWrite7, commitChanWrite7, 
                                  iAmTheLeaderRead0, timerWrite, 
                                  nextIndexInRead, termRead, logInRead, 
                                  logInRead0, logInRead1, commitInRead, 
                                  networkWrite11, networkWrite12, 
                                  networkWrite13, timerWrite0, networkWrite14, 
                                  timerWrite1, networkWrite15, msg_, null, 
                                  heartbeatId, proposerId, counter, requestId, 
                                  proposal, result_, result, learnerId, 
                                  decided, timeoutLocal, currentTerm, votedFor, 
                                  log, state, commitIndex, lastApplied, 
                                  nextIndex, matchIndex, iterator, votes, 
                                  value, msg, response, msgs, index, next >>

TimeoutCheck(self) == /\ pc[self] = "TimeoutCheck"
                      /\ \/ /\ timeoutRead' = FALSE
                         \/ /\ timeoutRead' = TRUE
                      /\ IF ((state[self]) # (Leader)) /\ (timeoutRead')
                            THEN /\ state' = [state EXCEPT ![self] = Candidate]
                                 /\ currentTerm' = [currentTerm EXCEPT ![self] = (currentTerm[self]) + (1)]
                                 /\ votes' = [votes EXCEPT ![self][currentTerm'[self]] = {self}]
                                 /\ votedFor' = [votedFor EXCEPT ![self] = self]
                                 /\ iterator' = [iterator EXCEPT ![self] = 0]
                                 /\ pc' = [pc EXCEPT ![self] = "SendReqVotes"]
                                 /\ UNCHANGED << mailboxes, networkWrite1 >>
                            ELSE /\ networkWrite1' = mailboxes
                                 /\ mailboxes' = networkWrite1'
                                 /\ pc' = [pc EXCEPT ![self] = "LeaderCheck"]
                                 /\ UNCHANGED << currentTerm, votedFor, state, 
                                                 iterator, votes >>
                      /\ UNCHANGED << values, requestSet, learnedChan, 
                                      raftLayerChan, kvClient, idAbstract, 
                                      database, iAmTheLeaderAbstract, 
                                      frequency, terms, lastSeen, nexts, logs, 
                                      commits, requestsRead, requestsWrite, 
                                      iAmTheLeaderRead, proposerChanWrite, 
                                      raftChanRead, raftChanWrite, 
                                      upstreamWrite, proposerChanWrite0, 
                                      raftChanWrite0, upstreamWrite0, 
                                      requestsWrite0, proposerChanWrite1, 
                                      raftChanWrite1, upstreamWrite1, 
                                      learnerChanRead, learnerChanWrite, 
                                      kvIdRead, dbWrite, dbWrite0, kvIdRead0, 
                                      kvIdRead1, dbRead, kvIdRead2, 
                                      requestServiceWrite, 
                                      requestServiceWrite0, learnerChanWrite0, 
                                      dbWrite1, requestServiceWrite1, 
                                      networkWrite, networkWrite0, inputRead, 
                                      inputWrite, logChanWrite, nextChanWrite, 
                                      commitChanWrite, appliedWrite, 
                                      appliedWrite0, networkWrite2, 
                                      networkWrite3, inputWrite0, 
                                      logChanWrite0, nextChanWrite0, 
                                      commitChanWrite0, appliedWrite1, 
                                      networkWrite4, networkRead, 
                                      iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                      lastmsgWrite, lastmsgWrite0, 
                                      lastmsgWrite1, ifResult, appliedWrite2, 
                                      appliedWrite3, ifResult0, nextChanWrite1, 
                                      networkWrite5, termWrite, 
                                      iAmTheLeaderWrite1, termWrite0, 
                                      logChanWrite1, commitChanWrite1, 
                                      nextChanWrite2, iAmTheLeaderWrite2, 
                                      termWrite1, logChanWrite2, 
                                      commitChanWrite2, nextChanWrite3, 
                                      iAmTheLeaderWrite3, termWrite2, 
                                      logChanWrite3, commitChanWrite3, 
                                      nextChanWrite4, nextChanWrite5, 
                                      networkWrite6, iAmTheLeaderWrite4, 
                                      termWrite3, logChanWrite4, 
                                      commitChanWrite4, networkWrite7, 
                                      nextChanWrite6, iAmTheLeaderWrite5, 
                                      termWrite4, logChanWrite5, 
                                      commitChanWrite5, lastmsgWrite2, 
                                      networkWrite8, appliedWrite4, 
                                      nextChanWrite7, iAmTheLeaderWrite6, 
                                      termWrite5, logChanWrite6, 
                                      commitChanWrite6, iAmTheLeaderWrite7, 
                                      lastmsgWrite3, networkWrite9, 
                                      appliedWrite5, nextChanWrite8, 
                                      termWrite6, logChanWrite7, 
                                      commitChanWrite7, networkWrite10, 
                                      inputWrite1, logChanWrite8, 
                                      nextChanWrite9, commitChanWrite8, 
                                      appliedWrite6, iAmTheLeaderWrite8, 
                                      lastmsgWrite4, termWrite7, 
                                      iAmTheLeaderRead0, timerWrite, 
                                      nextIndexInRead, termRead, logInRead, 
                                      logInRead0, logInRead1, commitInRead, 
                                      networkWrite11, networkWrite12, 
                                      networkWrite13, timerWrite0, 
                                      networkWrite14, timerWrite1, 
                                      networkWrite15, msg_, null, heartbeatId, 
                                      proposerId, counter, requestId, proposal, 
                                      result_, result, learnerId, decided, 
                                      timeoutLocal, log, commitIndex, 
                                      lastApplied, nextIndex, matchIndex, 
                                      value, msg, response, msgs, index, next >>

SendReqVotes(self) == /\ pc[self] = "SendReqVotes"
                      /\ IF (iterator[self]) < (NUM_NODES)
                            THEN /\ networkWrite' = [mailboxes EXCEPT ![iterator[self]] = Append(mailboxes[iterator[self]], [sender |-> self, type |-> RequestVote, term |-> currentTerm[self], granted |-> FALSE, entries |-> <<>>, prevIndex |-> Len(log[self]), prevTerm |-> Term(log[self], Len(log[self])), commit |-> NULL])]
                                 /\ iterator' = [iterator EXCEPT ![self] = (iterator[self]) + (1)]
                                 /\ networkWrite0' = networkWrite'
                                 /\ mailboxes' = networkWrite0'
                                 /\ pc' = [pc EXCEPT ![self] = "SendReqVotes"]
                            ELSE /\ networkWrite0' = mailboxes
                                 /\ mailboxes' = networkWrite0'
                                 /\ pc' = [pc EXCEPT ![self] = "LeaderCheck"]
                                 /\ UNCHANGED << networkWrite, iterator >>
                      /\ UNCHANGED << values, requestSet, learnedChan, 
                                      raftLayerChan, kvClient, idAbstract, 
                                      database, iAmTheLeaderAbstract, 
                                      frequency, terms, lastSeen, nexts, logs, 
                                      commits, requestsRead, requestsWrite, 
                                      iAmTheLeaderRead, proposerChanWrite, 
                                      raftChanRead, raftChanWrite, 
                                      upstreamWrite, proposerChanWrite0, 
                                      raftChanWrite0, upstreamWrite0, 
                                      requestsWrite0, proposerChanWrite1, 
                                      raftChanWrite1, upstreamWrite1, 
                                      learnerChanRead, learnerChanWrite, 
                                      kvIdRead, dbWrite, dbWrite0, kvIdRead0, 
                                      kvIdRead1, dbRead, kvIdRead2, 
                                      requestServiceWrite, 
                                      requestServiceWrite0, learnerChanWrite0, 
                                      dbWrite1, requestServiceWrite1, 
                                      timeoutRead, networkWrite1, inputRead, 
                                      inputWrite, logChanWrite, nextChanWrite, 
                                      commitChanWrite, appliedWrite, 
                                      appliedWrite0, networkWrite2, 
                                      networkWrite3, inputWrite0, 
                                      logChanWrite0, nextChanWrite0, 
                                      commitChanWrite0, appliedWrite1, 
                                      networkWrite4, networkRead, 
                                      iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                      lastmsgWrite, lastmsgWrite0, 
                                      lastmsgWrite1, ifResult, appliedWrite2, 
                                      appliedWrite3, ifResult0, nextChanWrite1, 
                                      networkWrite5, termWrite, 
                                      iAmTheLeaderWrite1, termWrite0, 
                                      logChanWrite1, commitChanWrite1, 
                                      nextChanWrite2, iAmTheLeaderWrite2, 
                                      termWrite1, logChanWrite2, 
                                      commitChanWrite2, nextChanWrite3, 
                                      iAmTheLeaderWrite3, termWrite2, 
                                      logChanWrite3, commitChanWrite3, 
                                      nextChanWrite4, nextChanWrite5, 
                                      networkWrite6, iAmTheLeaderWrite4, 
                                      termWrite3, logChanWrite4, 
                                      commitChanWrite4, networkWrite7, 
                                      nextChanWrite6, iAmTheLeaderWrite5, 
                                      termWrite4, logChanWrite5, 
                                      commitChanWrite5, lastmsgWrite2, 
                                      networkWrite8, appliedWrite4, 
                                      nextChanWrite7, iAmTheLeaderWrite6, 
                                      termWrite5, logChanWrite6, 
                                      commitChanWrite6, iAmTheLeaderWrite7, 
                                      lastmsgWrite3, networkWrite9, 
                                      appliedWrite5, nextChanWrite8, 
                                      termWrite6, logChanWrite7, 
                                      commitChanWrite7, networkWrite10, 
                                      inputWrite1, logChanWrite8, 
                                      nextChanWrite9, commitChanWrite8, 
                                      appliedWrite6, iAmTheLeaderWrite8, 
                                      lastmsgWrite4, termWrite7, 
                                      iAmTheLeaderRead0, timerWrite, 
                                      nextIndexInRead, termRead, logInRead, 
                                      logInRead0, logInRead1, commitInRead, 
                                      networkWrite11, networkWrite12, 
                                      networkWrite13, timerWrite0, 
                                      networkWrite14, timerWrite1, 
                                      networkWrite15, msg_, null, heartbeatId, 
                                      proposerId, counter, requestId, proposal, 
                                      result_, result, learnerId, decided, 
                                      timeoutLocal, currentTerm, votedFor, log, 
                                      state, commitIndex, lastApplied, 
                                      nextIndex, matchIndex, votes, value, msg, 
                                      response, msgs, index, next >>

LeaderCheck(self) == /\ pc[self] = "LeaderCheck"
                     /\ IF (state[self]) = (Leader)
                           THEN /\ pc' = [pc EXCEPT ![self] = "GetVal"]
                                /\ UNCHANGED << values, learnedChan, nexts, 
                                                logs, commits, mailboxes, 
                                                inputWrite0, logChanWrite0, 
                                                nextChanWrite0, 
                                                commitChanWrite0, 
                                                appliedWrite1, networkWrite4 >>
                           ELSE /\ inputWrite0' = values
                                /\ logChanWrite0' = logs
                                /\ nextChanWrite0' = nexts
                                /\ commitChanWrite0' = commits
                                /\ appliedWrite1' = learnedChan
                                /\ networkWrite4' = mailboxes
                                /\ mailboxes' = networkWrite4'
                                /\ learnedChan' = appliedWrite1'
                                /\ values' = inputWrite0'
                                /\ nexts' = nextChanWrite0'
                                /\ logs' = logChanWrite0'
                                /\ commits' = commitChanWrite0'
                                /\ pc' = [pc EXCEPT ![self] = "RecvMsg"]
                     /\ UNCHANGED << requestSet, raftLayerChan, kvClient, 
                                     idAbstract, database, 
                                     iAmTheLeaderAbstract, frequency, terms, 
                                     lastSeen, requestsRead, requestsWrite, 
                                     iAmTheLeaderRead, proposerChanWrite, 
                                     raftChanRead, raftChanWrite, 
                                     upstreamWrite, proposerChanWrite0, 
                                     raftChanWrite0, upstreamWrite0, 
                                     requestsWrite0, proposerChanWrite1, 
                                     raftChanWrite1, upstreamWrite1, 
                                     learnerChanRead, learnerChanWrite, 
                                     kvIdRead, dbWrite, dbWrite0, kvIdRead0, 
                                     kvIdRead1, dbRead, kvIdRead2, 
                                     requestServiceWrite, requestServiceWrite0, 
                                     learnerChanWrite0, dbWrite1, 
                                     requestServiceWrite1, timeoutRead, 
                                     networkWrite, networkWrite0, 
                                     networkWrite1, inputRead, inputWrite, 
                                     logChanWrite, nextChanWrite, 
                                     commitChanWrite, appliedWrite, 
                                     appliedWrite0, networkWrite2, 
                                     networkWrite3, networkRead, 
                                     iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                     lastmsgWrite, lastmsgWrite0, 
                                     lastmsgWrite1, ifResult, appliedWrite2, 
                                     appliedWrite3, ifResult0, nextChanWrite1, 
                                     networkWrite5, termWrite, 
                                     iAmTheLeaderWrite1, termWrite0, 
                                     logChanWrite1, commitChanWrite1, 
                                     nextChanWrite2, iAmTheLeaderWrite2, 
                                     termWrite1, logChanWrite2, 
                                     commitChanWrite2, nextChanWrite3, 
                                     iAmTheLeaderWrite3, termWrite2, 
                                     logChanWrite3, commitChanWrite3, 
                                     nextChanWrite4, nextChanWrite5, 
                                     networkWrite6, iAmTheLeaderWrite4, 
                                     termWrite3, logChanWrite4, 
                                     commitChanWrite4, networkWrite7, 
                                     nextChanWrite6, iAmTheLeaderWrite5, 
                                     termWrite4, logChanWrite5, 
                                     commitChanWrite5, lastmsgWrite2, 
                                     networkWrite8, appliedWrite4, 
                                     nextChanWrite7, iAmTheLeaderWrite6, 
                                     termWrite5, logChanWrite6, 
                                     commitChanWrite6, iAmTheLeaderWrite7, 
                                     lastmsgWrite3, networkWrite9, 
                                     appliedWrite5, nextChanWrite8, termWrite6, 
                                     logChanWrite7, commitChanWrite7, 
                                     networkWrite10, inputWrite1, 
                                     logChanWrite8, nextChanWrite9, 
                                     commitChanWrite8, appliedWrite6, 
                                     iAmTheLeaderWrite8, lastmsgWrite4, 
                                     termWrite7, iAmTheLeaderRead0, timerWrite, 
                                     nextIndexInRead, termRead, logInRead, 
                                     logInRead0, logInRead1, commitInRead, 
                                     networkWrite11, networkWrite12, 
                                     networkWrite13, timerWrite0, 
                                     networkWrite14, timerWrite1, 
                                     networkWrite15, msg_, null, heartbeatId, 
                                     proposerId, counter, requestId, proposal, 
                                     result_, result, learnerId, decided, 
                                     timeoutLocal, currentTerm, votedFor, log, 
                                     state, commitIndex, lastApplied, 
                                     nextIndex, matchIndex, iterator, votes, 
                                     value, msg, response, msgs, index, next >>

GetVal(self) == /\ pc[self] = "GetVal"
                /\ (Len(values[self])) > (0)
                /\ LET msg2 == Head(values[self]) IN
                     /\ inputWrite' = [values EXCEPT ![self] = Tail(values[self])]
                     /\ inputRead' = msg2
                /\ value' = [value EXCEPT ![self] = inputRead']
                /\ log' = [log EXCEPT ![self] = Append(log[self], [val |-> value'[self], term |-> currentTerm[self]])]
                /\ matchIndex' = [matchIndex EXCEPT ![self][self] = Len(log'[self])]
                /\ nextIndex' = [nextIndex EXCEPT ![self][self] = (Len(log'[self])) + (1)]
                /\ logChanWrite' = [logs EXCEPT ![self] = log'[self]]
                /\ nextChanWrite' = [nexts EXCEPT ![self] = nextIndex'[self]]
                /\ values' = inputWrite'
                /\ nexts' = nextChanWrite'
                /\ logs' = logChanWrite'
                /\ pc' = [pc EXCEPT ![self] = "AdvanceIndex"]
                /\ UNCHANGED << requestSet, learnedChan, raftLayerChan, 
                                kvClient, idAbstract, database, 
                                iAmTheLeaderAbstract, frequency, terms, 
                                lastSeen, commits, mailboxes, requestsRead, 
                                requestsWrite, iAmTheLeaderRead, 
                                proposerChanWrite, raftChanRead, raftChanWrite, 
                                upstreamWrite, proposerChanWrite0, 
                                raftChanWrite0, upstreamWrite0, requestsWrite0, 
                                proposerChanWrite1, raftChanWrite1, 
                                upstreamWrite1, learnerChanRead, 
                                learnerChanWrite, kvIdRead, dbWrite, dbWrite0, 
                                kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
                                requestServiceWrite, requestServiceWrite0, 
                                learnerChanWrite0, dbWrite1, 
                                requestServiceWrite1, timeoutRead, 
                                networkWrite, networkWrite0, networkWrite1, 
                                commitChanWrite, appliedWrite, appliedWrite0, 
                                networkWrite2, networkWrite3, inputWrite0, 
                                logChanWrite0, nextChanWrite0, 
                                commitChanWrite0, appliedWrite1, networkWrite4, 
                                networkRead, iAmTheLeaderWrite, 
                                iAmTheLeaderWrite0, lastmsgWrite, 
                                lastmsgWrite0, lastmsgWrite1, ifResult, 
                                appliedWrite2, appliedWrite3, ifResult0, 
                                nextChanWrite1, networkWrite5, termWrite, 
                                iAmTheLeaderWrite1, termWrite0, logChanWrite1, 
                                commitChanWrite1, nextChanWrite2, 
                                iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
                                commitChanWrite2, nextChanWrite3, 
                                iAmTheLeaderWrite3, termWrite2, logChanWrite3, 
                                commitChanWrite3, nextChanWrite4, 
                                nextChanWrite5, networkWrite6, 
                                iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
                                commitChanWrite4, networkWrite7, 
                                nextChanWrite6, iAmTheLeaderWrite5, termWrite4, 
                                logChanWrite5, commitChanWrite5, lastmsgWrite2, 
                                networkWrite8, appliedWrite4, nextChanWrite7, 
                                iAmTheLeaderWrite6, termWrite5, logChanWrite6, 
                                commitChanWrite6, iAmTheLeaderWrite7, 
                                lastmsgWrite3, networkWrite9, appliedWrite5, 
                                nextChanWrite8, termWrite6, logChanWrite7, 
                                commitChanWrite7, networkWrite10, inputWrite1, 
                                logChanWrite8, nextChanWrite9, 
                                commitChanWrite8, appliedWrite6, 
                                iAmTheLeaderWrite8, lastmsgWrite4, termWrite7, 
                                iAmTheLeaderRead0, timerWrite, nextIndexInRead, 
                                termRead, logInRead, logInRead0, logInRead1, 
                                commitInRead, networkWrite11, networkWrite12, 
                                networkWrite13, timerWrite0, networkWrite14, 
                                timerWrite1, networkWrite15, msg_, null, 
                                heartbeatId, proposerId, counter, requestId, 
                                proposal, result_, result, learnerId, decided, 
                                timeoutLocal, currentTerm, votedFor, state, 
                                commitIndex, lastApplied, iterator, votes, msg, 
                                response, msgs, index, next >>

AdvanceIndex(self) == /\ pc[self] = "AdvanceIndex"
                      /\ IF (((Cardinality({i \in Servers : (matchIndex[self][i]) > (commitIndex[self])})) * (2)) > (Cardinality(Servers))) /\ ((Term(log[self], (commitIndex[self]) + (1))) = (currentTerm[self]))
                            THEN /\ commitIndex' = [commitIndex EXCEPT ![self] = (commitIndex[self]) + (1)]
                                 /\ pc' = [pc EXCEPT ![self] = "AdvanceIndex"]
                            ELSE /\ pc' = [pc EXCEPT ![self] = "UpdateCommit"]
                                 /\ UNCHANGED commitIndex
                      /\ UNCHANGED << values, requestSet, learnedChan, 
                                      raftLayerChan, kvClient, idAbstract, 
                                      database, iAmTheLeaderAbstract, 
                                      frequency, terms, lastSeen, nexts, logs, 
                                      commits, mailboxes, requestsRead, 
                                      requestsWrite, iAmTheLeaderRead, 
                                      proposerChanWrite, raftChanRead, 
                                      raftChanWrite, upstreamWrite, 
                                      proposerChanWrite0, raftChanWrite0, 
                                      upstreamWrite0, requestsWrite0, 
                                      proposerChanWrite1, raftChanWrite1, 
                                      upstreamWrite1, learnerChanRead, 
                                      learnerChanWrite, kvIdRead, dbWrite, 
                                      dbWrite0, kvIdRead0, kvIdRead1, dbRead, 
                                      kvIdRead2, requestServiceWrite, 
                                      requestServiceWrite0, learnerChanWrite0, 
                                      dbWrite1, requestServiceWrite1, 
                                      timeoutRead, networkWrite, networkWrite0, 
                                      networkWrite1, inputRead, inputWrite, 
                                      logChanWrite, nextChanWrite, 
                                      commitChanWrite, appliedWrite, 
                                      appliedWrite0, networkWrite2, 
                                      networkWrite3, inputWrite0, 
                                      logChanWrite0, nextChanWrite0, 
                                      commitChanWrite0, appliedWrite1, 
                                      networkWrite4, networkRead, 
                                      iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                      lastmsgWrite, lastmsgWrite0, 
                                      lastmsgWrite1, ifResult, appliedWrite2, 
                                      appliedWrite3, ifResult0, nextChanWrite1, 
                                      networkWrite5, termWrite, 
                                      iAmTheLeaderWrite1, termWrite0, 
                                      logChanWrite1, commitChanWrite1, 
                                      nextChanWrite2, iAmTheLeaderWrite2, 
                                      termWrite1, logChanWrite2, 
                                      commitChanWrite2, nextChanWrite3, 
                                      iAmTheLeaderWrite3, termWrite2, 
                                      logChanWrite3, commitChanWrite3, 
                                      nextChanWrite4, nextChanWrite5, 
                                      networkWrite6, iAmTheLeaderWrite4, 
                                      termWrite3, logChanWrite4, 
                                      commitChanWrite4, networkWrite7, 
                                      nextChanWrite6, iAmTheLeaderWrite5, 
                                      termWrite4, logChanWrite5, 
                                      commitChanWrite5, lastmsgWrite2, 
                                      networkWrite8, appliedWrite4, 
                                      nextChanWrite7, iAmTheLeaderWrite6, 
                                      termWrite5, logChanWrite6, 
                                      commitChanWrite6, iAmTheLeaderWrite7, 
                                      lastmsgWrite3, networkWrite9, 
                                      appliedWrite5, nextChanWrite8, 
                                      termWrite6, logChanWrite7, 
                                      commitChanWrite7, networkWrite10, 
                                      inputWrite1, logChanWrite8, 
                                      nextChanWrite9, commitChanWrite8, 
                                      appliedWrite6, iAmTheLeaderWrite8, 
                                      lastmsgWrite4, termWrite7, 
                                      iAmTheLeaderRead0, timerWrite, 
                                      nextIndexInRead, termRead, logInRead, 
                                      logInRead0, logInRead1, commitInRead, 
                                      networkWrite11, networkWrite12, 
                                      networkWrite13, timerWrite0, 
                                      networkWrite14, timerWrite1, 
                                      networkWrite15, msg_, null, heartbeatId, 
                                      proposerId, counter, requestId, proposal, 
                                      result_, result, learnerId, decided, 
                                      timeoutLocal, currentTerm, votedFor, log, 
                                      state, lastApplied, nextIndex, 
                                      matchIndex, iterator, votes, value, msg, 
                                      response, msgs, index, next >>

UpdateCommit(self) == /\ pc[self] = "UpdateCommit"
                      /\ commitChanWrite' = [commits EXCEPT ![self] = commitIndex[self]]
                      /\ commits' = commitChanWrite'
                      /\ pc' = [pc EXCEPT ![self] = "ApplyCommited"]
                      /\ UNCHANGED << values, requestSet, learnedChan, 
                                      raftLayerChan, kvClient, idAbstract, 
                                      database, iAmTheLeaderAbstract, 
                                      frequency, terms, lastSeen, nexts, logs, 
                                      mailboxes, requestsRead, requestsWrite, 
                                      iAmTheLeaderRead, proposerChanWrite, 
                                      raftChanRead, raftChanWrite, 
                                      upstreamWrite, proposerChanWrite0, 
                                      raftChanWrite0, upstreamWrite0, 
                                      requestsWrite0, proposerChanWrite1, 
                                      raftChanWrite1, upstreamWrite1, 
                                      learnerChanRead, learnerChanWrite, 
                                      kvIdRead, dbWrite, dbWrite0, kvIdRead0, 
                                      kvIdRead1, dbRead, kvIdRead2, 
                                      requestServiceWrite, 
                                      requestServiceWrite0, learnerChanWrite0, 
                                      dbWrite1, requestServiceWrite1, 
                                      timeoutRead, networkWrite, networkWrite0, 
                                      networkWrite1, inputRead, inputWrite, 
                                      logChanWrite, nextChanWrite, 
                                      appliedWrite, appliedWrite0, 
                                      networkWrite2, networkWrite3, 
                                      inputWrite0, logChanWrite0, 
                                      nextChanWrite0, commitChanWrite0, 
                                      appliedWrite1, networkWrite4, 
                                      networkRead, iAmTheLeaderWrite, 
                                      iAmTheLeaderWrite0, lastmsgWrite, 
                                      lastmsgWrite0, lastmsgWrite1, ifResult, 
                                      appliedWrite2, appliedWrite3, ifResult0, 
                                      nextChanWrite1, networkWrite5, termWrite, 
                                      iAmTheLeaderWrite1, termWrite0, 
                                      logChanWrite1, commitChanWrite1, 
                                      nextChanWrite2, iAmTheLeaderWrite2, 
                                      termWrite1, logChanWrite2, 
                                      commitChanWrite2, nextChanWrite3, 
                                      iAmTheLeaderWrite3, termWrite2, 
                                      logChanWrite3, commitChanWrite3, 
                                      nextChanWrite4, nextChanWrite5, 
                                      networkWrite6, iAmTheLeaderWrite4, 
                                      termWrite3, logChanWrite4, 
                                      commitChanWrite4, networkWrite7, 
                                      nextChanWrite6, iAmTheLeaderWrite5, 
                                      termWrite4, logChanWrite5, 
                                      commitChanWrite5, lastmsgWrite2, 
                                      networkWrite8, appliedWrite4, 
                                      nextChanWrite7, iAmTheLeaderWrite6, 
                                      termWrite5, logChanWrite6, 
                                      commitChanWrite6, iAmTheLeaderWrite7, 
                                      lastmsgWrite3, networkWrite9, 
                                      appliedWrite5, nextChanWrite8, 
                                      termWrite6, logChanWrite7, 
                                      commitChanWrite7, networkWrite10, 
                                      inputWrite1, logChanWrite8, 
                                      nextChanWrite9, commitChanWrite8, 
                                      appliedWrite6, iAmTheLeaderWrite8, 
                                      lastmsgWrite4, termWrite7, 
                                      iAmTheLeaderRead0, timerWrite, 
                                      nextIndexInRead, termRead, logInRead, 
                                      logInRead0, logInRead1, commitInRead, 
                                      networkWrite11, networkWrite12, 
                                      networkWrite13, timerWrite0, 
                                      networkWrite14, timerWrite1, 
                                      networkWrite15, msg_, null, heartbeatId, 
                                      proposerId, counter, requestId, proposal, 
                                      result_, result, learnerId, decided, 
                                      timeoutLocal, currentTerm, votedFor, log, 
                                      state, commitIndex, lastApplied, 
                                      nextIndex, matchIndex, iterator, votes, 
                                      value, msg, response, msgs, index, next >>

ApplyCommited(self) == /\ pc[self] = "ApplyCommited"
                       /\ IF (lastApplied[self]) < (commitIndex[self])
                             THEN /\ lastApplied' = [lastApplied EXCEPT ![self] = (lastApplied[self]) + (1)]
                                  /\ (Len(learnedChan[self])) < (BUFFER_SIZE)
                                  /\ appliedWrite' = [learnedChan EXCEPT ![self] = Append(learnedChan[self], (log[self][lastApplied'[self]]).val)]
                                  /\ appliedWrite0' = appliedWrite'
                                  /\ learnedChan' = appliedWrite0'
                                  /\ pc' = [pc EXCEPT ![self] = "ApplyCommited"]
                                  /\ UNCHANGED iterator
                             ELSE /\ iterator' = [iterator EXCEPT ![self] = 0]
                                  /\ appliedWrite0' = learnedChan
                                  /\ learnedChan' = appliedWrite0'
                                  /\ pc' = [pc EXCEPT ![self] = "SendAppendEntries"]
                                  /\ UNCHANGED << appliedWrite, lastApplied >>
                       /\ UNCHANGED << values, requestSet, raftLayerChan, 
                                       kvClient, idAbstract, database, 
                                       iAmTheLeaderAbstract, frequency, terms, 
                                       lastSeen, nexts, logs, commits, 
                                       mailboxes, requestsRead, requestsWrite, 
                                       iAmTheLeaderRead, proposerChanWrite, 
                                       raftChanRead, raftChanWrite, 
                                       upstreamWrite, proposerChanWrite0, 
                                       raftChanWrite0, upstreamWrite0, 
                                       requestsWrite0, proposerChanWrite1, 
                                       raftChanWrite1, upstreamWrite1, 
                                       learnerChanRead, learnerChanWrite, 
                                       kvIdRead, dbWrite, dbWrite0, kvIdRead0, 
                                       kvIdRead1, dbRead, kvIdRead2, 
                                       requestServiceWrite, 
                                       requestServiceWrite0, learnerChanWrite0, 
                                       dbWrite1, requestServiceWrite1, 
                                       timeoutRead, networkWrite, 
                                       networkWrite0, networkWrite1, inputRead, 
                                       inputWrite, logChanWrite, nextChanWrite, 
                                       commitChanWrite, networkWrite2, 
                                       networkWrite3, inputWrite0, 
                                       logChanWrite0, nextChanWrite0, 
                                       commitChanWrite0, appliedWrite1, 
                                       networkWrite4, networkRead, 
                                       iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                       lastmsgWrite, lastmsgWrite0, 
                                       lastmsgWrite1, ifResult, appliedWrite2, 
                                       appliedWrite3, ifResult0, 
                                       nextChanWrite1, networkWrite5, 
                                       termWrite, iAmTheLeaderWrite1, 
                                       termWrite0, logChanWrite1, 
                                       commitChanWrite1, nextChanWrite2, 
                                       iAmTheLeaderWrite2, termWrite1, 
                                       logChanWrite2, commitChanWrite2, 
                                       nextChanWrite3, iAmTheLeaderWrite3, 
                                       termWrite2, logChanWrite3, 
                                       commitChanWrite3, nextChanWrite4, 
                                       nextChanWrite5, networkWrite6, 
                                       iAmTheLeaderWrite4, termWrite3, 
                                       logChanWrite4, commitChanWrite4, 
                                       networkWrite7, nextChanWrite6, 
                                       iAmTheLeaderWrite5, termWrite4, 
                                       logChanWrite5, commitChanWrite5, 
                                       lastmsgWrite2, networkWrite8, 
                                       appliedWrite4, nextChanWrite7, 
                                       iAmTheLeaderWrite6, termWrite5, 
                                       logChanWrite6, commitChanWrite6, 
                                       iAmTheLeaderWrite7, lastmsgWrite3, 
                                       networkWrite9, appliedWrite5, 
                                       nextChanWrite8, termWrite6, 
                                       logChanWrite7, commitChanWrite7, 
                                       networkWrite10, inputWrite1, 
                                       logChanWrite8, nextChanWrite9, 
                                       commitChanWrite8, appliedWrite6, 
                                       iAmTheLeaderWrite8, lastmsgWrite4, 
                                       termWrite7, iAmTheLeaderRead0, 
                                       timerWrite, nextIndexInRead, termRead, 
                                       logInRead, logInRead0, logInRead1, 
                                       commitInRead, networkWrite11, 
                                       networkWrite12, networkWrite13, 
                                       timerWrite0, networkWrite14, 
                                       timerWrite1, networkWrite15, msg_, null, 
                                       heartbeatId, proposerId, counter, 
                                       requestId, proposal, result_, result, 
                                       learnerId, decided, timeoutLocal, 
                                       currentTerm, votedFor, log, state, 
                                       commitIndex, nextIndex, matchIndex, 
                                       votes, value, msg, response, msgs, 
                                       index, next >>

SendAppendEntries(self) == /\ pc[self] = "SendAppendEntries"
                           /\ IF (iterator[self]) < (NUM_NODES)
                                 THEN /\ IF (iterator[self]) # (self)
                                            THEN /\ networkWrite' = [mailboxes EXCEPT ![iterator[self]] = Append(mailboxes[iterator[self]], [sender |-> self, type |-> AppendEntries, term |-> currentTerm[self], granted |-> FALSE, entries |-> SubSeq(log[self], nextIndex[self][iterator[self]], Len(log[self])), prevIndex |-> (nextIndex[self][iterator[self]]) - (1), prevTerm |-> Term(log[self], (nextIndex[self][iterator[self]]) - (1)), commit |-> commitIndex[self]])]
                                                 /\ networkWrite2' = networkWrite'
                                            ELSE /\ networkWrite2' = mailboxes
                                                 /\ UNCHANGED networkWrite
                                      /\ iterator' = [iterator EXCEPT ![self] = (iterator[self]) + (1)]
                                      /\ networkWrite3' = networkWrite2'
                                      /\ mailboxes' = networkWrite3'
                                      /\ pc' = [pc EXCEPT ![self] = "SendAppendEntries"]
                                 ELSE /\ networkWrite3' = mailboxes
                                      /\ mailboxes' = networkWrite3'
                                      /\ pc' = [pc EXCEPT ![self] = "RecvMsg"]
                                      /\ UNCHANGED << networkWrite, 
                                                      networkWrite2, iterator >>
                           /\ UNCHANGED << values, requestSet, learnedChan, 
                                           raftLayerChan, kvClient, idAbstract, 
                                           database, iAmTheLeaderAbstract, 
                                           frequency, terms, lastSeen, nexts, 
                                           logs, commits, requestsRead, 
                                           requestsWrite, iAmTheLeaderRead, 
                                           proposerChanWrite, raftChanRead, 
                                           raftChanWrite, upstreamWrite, 
                                           proposerChanWrite0, raftChanWrite0, 
                                           upstreamWrite0, requestsWrite0, 
                                           proposerChanWrite1, raftChanWrite1, 
                                           upstreamWrite1, learnerChanRead, 
                                           learnerChanWrite, kvIdRead, dbWrite, 
                                           dbWrite0, kvIdRead0, kvIdRead1, 
                                           dbRead, kvIdRead2, 
                                           requestServiceWrite, 
                                           requestServiceWrite0, 
                                           learnerChanWrite0, dbWrite1, 
                                           requestServiceWrite1, timeoutRead, 
                                           networkWrite0, networkWrite1, 
                                           inputRead, inputWrite, logChanWrite, 
                                           nextChanWrite, commitChanWrite, 
                                           appliedWrite, appliedWrite0, 
                                           inputWrite0, logChanWrite0, 
                                           nextChanWrite0, commitChanWrite0, 
                                           appliedWrite1, networkWrite4, 
                                           networkRead, iAmTheLeaderWrite, 
                                           iAmTheLeaderWrite0, lastmsgWrite, 
                                           lastmsgWrite0, lastmsgWrite1, 
                                           ifResult, appliedWrite2, 
                                           appliedWrite3, ifResult0, 
                                           nextChanWrite1, networkWrite5, 
                                           termWrite, iAmTheLeaderWrite1, 
                                           termWrite0, logChanWrite1, 
                                           commitChanWrite1, nextChanWrite2, 
                                           iAmTheLeaderWrite2, termWrite1, 
                                           logChanWrite2, commitChanWrite2, 
                                           nextChanWrite3, iAmTheLeaderWrite3, 
                                           termWrite2, logChanWrite3, 
                                           commitChanWrite3, nextChanWrite4, 
                                           nextChanWrite5, networkWrite6, 
                                           iAmTheLeaderWrite4, termWrite3, 
                                           logChanWrite4, commitChanWrite4, 
                                           networkWrite7, nextChanWrite6, 
                                           iAmTheLeaderWrite5, termWrite4, 
                                           logChanWrite5, commitChanWrite5, 
                                           lastmsgWrite2, networkWrite8, 
                                           appliedWrite4, nextChanWrite7, 
                                           iAmTheLeaderWrite6, termWrite5, 
                                           logChanWrite6, commitChanWrite6, 
                                           iAmTheLeaderWrite7, lastmsgWrite3, 
                                           networkWrite9, appliedWrite5, 
                                           nextChanWrite8, termWrite6, 
                                           logChanWrite7, commitChanWrite7, 
                                           networkWrite10, inputWrite1, 
                                           logChanWrite8, nextChanWrite9, 
                                           commitChanWrite8, appliedWrite6, 
                                           iAmTheLeaderWrite8, lastmsgWrite4, 
                                           termWrite7, iAmTheLeaderRead0, 
                                           timerWrite, nextIndexInRead, 
                                           termRead, logInRead, logInRead0, 
                                           logInRead1, commitInRead, 
                                           networkWrite11, networkWrite12, 
                                           networkWrite13, timerWrite0, 
                                           networkWrite14, timerWrite1, 
                                           networkWrite15, msg_, null, 
                                           heartbeatId, proposerId, counter, 
                                           requestId, proposal, result_, 
                                           result, learnerId, decided, 
                                           timeoutLocal, currentTerm, votedFor, 
                                           log, state, commitIndex, 
                                           lastApplied, nextIndex, matchIndex, 
                                           votes, value, msg, response, msgs, 
                                           index, next >>

RecvMsg(self) == /\ pc[self] = "RecvMsg"
                 /\ LET msgs0 == mailboxes[self] IN
                      /\ networkWrite' = [mailboxes EXCEPT ![self] = <<>>]
                      /\ networkRead' = msgs0
                 /\ msgs' = [msgs EXCEPT ![self] = networkRead']
                 /\ mailboxes' = networkWrite'
                 /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                 /\ UNCHANGED << values, requestSet, learnedChan, 
                                 raftLayerChan, kvClient, idAbstract, database, 
                                 iAmTheLeaderAbstract, frequency, terms, 
                                 lastSeen, nexts, logs, commits, requestsRead, 
                                 requestsWrite, iAmTheLeaderRead, 
                                 proposerChanWrite, raftChanRead, 
                                 raftChanWrite, upstreamWrite, 
                                 proposerChanWrite0, raftChanWrite0, 
                                 upstreamWrite0, requestsWrite0, 
                                 proposerChanWrite1, raftChanWrite1, 
                                 upstreamWrite1, learnerChanRead, 
                                 learnerChanWrite, kvIdRead, dbWrite, dbWrite0, 
                                 kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
                                 requestServiceWrite, requestServiceWrite0, 
                                 learnerChanWrite0, dbWrite1, 
                                 requestServiceWrite1, timeoutRead, 
                                 networkWrite0, networkWrite1, inputRead, 
                                 inputWrite, logChanWrite, nextChanWrite, 
                                 commitChanWrite, appliedWrite, appliedWrite0, 
                                 networkWrite2, networkWrite3, inputWrite0, 
                                 logChanWrite0, nextChanWrite0, 
                                 commitChanWrite0, appliedWrite1, 
                                 networkWrite4, iAmTheLeaderWrite, 
                                 iAmTheLeaderWrite0, lastmsgWrite, 
                                 lastmsgWrite0, lastmsgWrite1, ifResult, 
                                 appliedWrite2, appliedWrite3, ifResult0, 
                                 nextChanWrite1, networkWrite5, termWrite, 
                                 iAmTheLeaderWrite1, termWrite0, logChanWrite1, 
                                 commitChanWrite1, nextChanWrite2, 
                                 iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
                                 commitChanWrite2, nextChanWrite3, 
                                 iAmTheLeaderWrite3, termWrite2, logChanWrite3, 
                                 commitChanWrite3, nextChanWrite4, 
                                 nextChanWrite5, networkWrite6, 
                                 iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
                                 commitChanWrite4, networkWrite7, 
                                 nextChanWrite6, iAmTheLeaderWrite5, 
                                 termWrite4, logChanWrite5, commitChanWrite5, 
                                 lastmsgWrite2, networkWrite8, appliedWrite4, 
                                 nextChanWrite7, iAmTheLeaderWrite6, 
                                 termWrite5, logChanWrite6, commitChanWrite6, 
                                 iAmTheLeaderWrite7, lastmsgWrite3, 
                                 networkWrite9, appliedWrite5, nextChanWrite8, 
                                 termWrite6, logChanWrite7, commitChanWrite7, 
                                 networkWrite10, inputWrite1, logChanWrite8, 
                                 nextChanWrite9, commitChanWrite8, 
                                 appliedWrite6, iAmTheLeaderWrite8, 
                                 lastmsgWrite4, termWrite7, iAmTheLeaderRead0, 
                                 timerWrite, nextIndexInRead, termRead, 
                                 logInRead, logInRead0, logInRead1, 
                                 commitInRead, networkWrite11, networkWrite12, 
                                 networkWrite13, timerWrite0, networkWrite14, 
                                 timerWrite1, networkWrite15, msg_, null, 
                                 heartbeatId, proposerId, counter, requestId, 
                                 proposal, result_, result, learnerId, decided, 
                                 timeoutLocal, currentTerm, votedFor, log, 
                                 state, commitIndex, lastApplied, nextIndex, 
                                 matchIndex, iterator, votes, value, msg, 
                                 response, index, next >>

ProcessMsgs(self) == /\ pc[self] = "ProcessMsgs"
                     /\ IF (Len(msgs[self])) > (0)
                           THEN /\ pc' = [pc EXCEPT ![self] = "GetMsg"]
                                /\ UNCHANGED << learnedChan, 
                                                iAmTheLeaderAbstract, terms, 
                                                lastSeen, nexts, logs, commits, 
                                                mailboxes, iAmTheLeaderWrite7, 
                                                lastmsgWrite3, networkWrite9, 
                                                appliedWrite5, nextChanWrite8, 
                                                termWrite6, logChanWrite7, 
                                                commitChanWrite7 >>
                           ELSE /\ iAmTheLeaderWrite7' = iAmTheLeaderAbstract
                                /\ lastmsgWrite3' = lastSeen
                                /\ networkWrite9' = mailboxes
                                /\ appliedWrite5' = learnedChan
                                /\ nextChanWrite8' = nexts
                                /\ termWrite6' = terms
                                /\ logChanWrite7' = logs
                                /\ commitChanWrite7' = commits
                                /\ mailboxes' = networkWrite9'
                                /\ learnedChan' = appliedWrite5'
                                /\ iAmTheLeaderAbstract' = iAmTheLeaderWrite7'
                                /\ terms' = termWrite6'
                                /\ lastSeen' = lastmsgWrite3'
                                /\ nexts' = nextChanWrite8'
                                /\ logs' = logChanWrite7'
                                /\ commits' = commitChanWrite7'
                                /\ pc' = [pc EXCEPT ![self] = "NodeLoop"]
                     /\ UNCHANGED << values, requestSet, raftLayerChan, 
                                     kvClient, idAbstract, database, frequency, 
                                     requestsRead, requestsWrite, 
                                     iAmTheLeaderRead, proposerChanWrite, 
                                     raftChanRead, raftChanWrite, 
                                     upstreamWrite, proposerChanWrite0, 
                                     raftChanWrite0, upstreamWrite0, 
                                     requestsWrite0, proposerChanWrite1, 
                                     raftChanWrite1, upstreamWrite1, 
                                     learnerChanRead, learnerChanWrite, 
                                     kvIdRead, dbWrite, dbWrite0, kvIdRead0, 
                                     kvIdRead1, dbRead, kvIdRead2, 
                                     requestServiceWrite, requestServiceWrite0, 
                                     learnerChanWrite0, dbWrite1, 
                                     requestServiceWrite1, timeoutRead, 
                                     networkWrite, networkWrite0, 
                                     networkWrite1, inputRead, inputWrite, 
                                     logChanWrite, nextChanWrite, 
                                     commitChanWrite, appliedWrite, 
                                     appliedWrite0, networkWrite2, 
                                     networkWrite3, inputWrite0, logChanWrite0, 
                                     nextChanWrite0, commitChanWrite0, 
                                     appliedWrite1, networkWrite4, networkRead, 
                                     iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                     lastmsgWrite, lastmsgWrite0, 
                                     lastmsgWrite1, ifResult, appliedWrite2, 
                                     appliedWrite3, ifResult0, nextChanWrite1, 
                                     networkWrite5, termWrite, 
                                     iAmTheLeaderWrite1, termWrite0, 
                                     logChanWrite1, commitChanWrite1, 
                                     nextChanWrite2, iAmTheLeaderWrite2, 
                                     termWrite1, logChanWrite2, 
                                     commitChanWrite2, nextChanWrite3, 
                                     iAmTheLeaderWrite3, termWrite2, 
                                     logChanWrite3, commitChanWrite3, 
                                     nextChanWrite4, nextChanWrite5, 
                                     networkWrite6, iAmTheLeaderWrite4, 
                                     termWrite3, logChanWrite4, 
                                     commitChanWrite4, networkWrite7, 
                                     nextChanWrite6, iAmTheLeaderWrite5, 
                                     termWrite4, logChanWrite5, 
                                     commitChanWrite5, lastmsgWrite2, 
                                     networkWrite8, appliedWrite4, 
                                     nextChanWrite7, iAmTheLeaderWrite6, 
                                     termWrite5, logChanWrite6, 
                                     commitChanWrite6, networkWrite10, 
                                     inputWrite1, logChanWrite8, 
                                     nextChanWrite9, commitChanWrite8, 
                                     appliedWrite6, iAmTheLeaderWrite8, 
                                     lastmsgWrite4, termWrite7, 
                                     iAmTheLeaderRead0, timerWrite, 
                                     nextIndexInRead, termRead, logInRead, 
                                     logInRead0, logInRead1, commitInRead, 
                                     networkWrite11, networkWrite12, 
                                     networkWrite13, timerWrite0, 
                                     networkWrite14, timerWrite1, 
                                     networkWrite15, msg_, null, heartbeatId, 
                                     proposerId, counter, requestId, proposal, 
                                     result_, result, learnerId, decided, 
                                     timeoutLocal, currentTerm, votedFor, log, 
                                     state, commitIndex, lastApplied, 
                                     nextIndex, matchIndex, iterator, votes, 
                                     value, msg, response, msgs, index, next >>

GetMsg(self) == /\ pc[self] = "GetMsg"
                /\ msg' = [msg EXCEPT ![self] = Head(msgs[self])]
                /\ msgs' = [msgs EXCEPT ![self] = Tail(msgs[self])]
                /\ pc' = [pc EXCEPT ![self] = "CheckMsgTerm"]
                /\ UNCHANGED << values, requestSet, learnedChan, raftLayerChan, 
                                kvClient, idAbstract, database, 
                                iAmTheLeaderAbstract, frequency, terms, 
                                lastSeen, nexts, logs, commits, mailboxes, 
                                requestsRead, requestsWrite, iAmTheLeaderRead, 
                                proposerChanWrite, raftChanRead, raftChanWrite, 
                                upstreamWrite, proposerChanWrite0, 
                                raftChanWrite0, upstreamWrite0, requestsWrite0, 
                                proposerChanWrite1, raftChanWrite1, 
                                upstreamWrite1, learnerChanRead, 
                                learnerChanWrite, kvIdRead, dbWrite, dbWrite0, 
                                kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
                                requestServiceWrite, requestServiceWrite0, 
                                learnerChanWrite0, dbWrite1, 
                                requestServiceWrite1, timeoutRead, 
                                networkWrite, networkWrite0, networkWrite1, 
                                inputRead, inputWrite, logChanWrite, 
                                nextChanWrite, commitChanWrite, appliedWrite, 
                                appliedWrite0, networkWrite2, networkWrite3, 
                                inputWrite0, logChanWrite0, nextChanWrite0, 
                                commitChanWrite0, appliedWrite1, networkWrite4, 
                                networkRead, iAmTheLeaderWrite, 
                                iAmTheLeaderWrite0, lastmsgWrite, 
                                lastmsgWrite0, lastmsgWrite1, ifResult, 
                                appliedWrite2, appliedWrite3, ifResult0, 
                                nextChanWrite1, networkWrite5, termWrite, 
                                iAmTheLeaderWrite1, termWrite0, logChanWrite1, 
                                commitChanWrite1, nextChanWrite2, 
                                iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
                                commitChanWrite2, nextChanWrite3, 
                                iAmTheLeaderWrite3, termWrite2, logChanWrite3, 
                                commitChanWrite3, nextChanWrite4, 
                                nextChanWrite5, networkWrite6, 
                                iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
                                commitChanWrite4, networkWrite7, 
                                nextChanWrite6, iAmTheLeaderWrite5, termWrite4, 
                                logChanWrite5, commitChanWrite5, lastmsgWrite2, 
                                networkWrite8, appliedWrite4, nextChanWrite7, 
                                iAmTheLeaderWrite6, termWrite5, logChanWrite6, 
                                commitChanWrite6, iAmTheLeaderWrite7, 
                                lastmsgWrite3, networkWrite9, appliedWrite5, 
                                nextChanWrite8, termWrite6, logChanWrite7, 
                                commitChanWrite7, networkWrite10, inputWrite1, 
                                logChanWrite8, nextChanWrite9, 
                                commitChanWrite8, appliedWrite6, 
                                iAmTheLeaderWrite8, lastmsgWrite4, termWrite7, 
                                iAmTheLeaderRead0, timerWrite, nextIndexInRead, 
                                termRead, logInRead, logInRead0, logInRead1, 
                                commitInRead, networkWrite11, networkWrite12, 
                                networkWrite13, timerWrite0, networkWrite14, 
                                timerWrite1, networkWrite15, msg_, null, 
                                heartbeatId, proposerId, counter, requestId, 
                                proposal, result_, result, learnerId, decided, 
                                timeoutLocal, currentTerm, votedFor, log, 
                                state, commitIndex, lastApplied, nextIndex, 
                                matchIndex, iterator, votes, value, response, 
                                index, next >>

CheckMsgTerm(self) == /\ pc[self] = "CheckMsgTerm"
                      /\ IF ((msg[self]).term) > (currentTerm[self])
                            THEN /\ iAmTheLeaderWrite' = [iAmTheLeaderAbstract EXCEPT ![(self) + (NUM_NODES)] = FALSE]
                                 /\ state' = [state EXCEPT ![self] = Follower]
                                 /\ currentTerm' = [currentTerm EXCEPT ![self] = (msg[self]).term]
                                 /\ votedFor' = [votedFor EXCEPT ![self] = NULL]
                                 /\ iAmTheLeaderWrite0' = iAmTheLeaderWrite'
                                 /\ iAmTheLeaderAbstract' = iAmTheLeaderWrite0'
                            ELSE /\ iAmTheLeaderWrite0' = iAmTheLeaderAbstract
                                 /\ iAmTheLeaderAbstract' = iAmTheLeaderWrite0'
                                 /\ UNCHANGED << iAmTheLeaderWrite, 
                                                 currentTerm, votedFor, state >>
                      /\ pc' = [pc EXCEPT ![self] = "MsgSwitch"]
                      /\ UNCHANGED << values, requestSet, learnedChan, 
                                      raftLayerChan, kvClient, idAbstract, 
                                      database, frequency, terms, lastSeen, 
                                      nexts, logs, commits, mailboxes, 
                                      requestsRead, requestsWrite, 
                                      iAmTheLeaderRead, proposerChanWrite, 
                                      raftChanRead, raftChanWrite, 
                                      upstreamWrite, proposerChanWrite0, 
                                      raftChanWrite0, upstreamWrite0, 
                                      requestsWrite0, proposerChanWrite1, 
                                      raftChanWrite1, upstreamWrite1, 
                                      learnerChanRead, learnerChanWrite, 
                                      kvIdRead, dbWrite, dbWrite0, kvIdRead0, 
                                      kvIdRead1, dbRead, kvIdRead2, 
                                      requestServiceWrite, 
                                      requestServiceWrite0, learnerChanWrite0, 
                                      dbWrite1, requestServiceWrite1, 
                                      timeoutRead, networkWrite, networkWrite0, 
                                      networkWrite1, inputRead, inputWrite, 
                                      logChanWrite, nextChanWrite, 
                                      commitChanWrite, appliedWrite, 
                                      appliedWrite0, networkWrite2, 
                                      networkWrite3, inputWrite0, 
                                      logChanWrite0, nextChanWrite0, 
                                      commitChanWrite0, appliedWrite1, 
                                      networkWrite4, networkRead, lastmsgWrite, 
                                      lastmsgWrite0, lastmsgWrite1, ifResult, 
                                      appliedWrite2, appliedWrite3, ifResult0, 
                                      nextChanWrite1, networkWrite5, termWrite, 
                                      iAmTheLeaderWrite1, termWrite0, 
                                      logChanWrite1, commitChanWrite1, 
                                      nextChanWrite2, iAmTheLeaderWrite2, 
                                      termWrite1, logChanWrite2, 
                                      commitChanWrite2, nextChanWrite3, 
                                      iAmTheLeaderWrite3, termWrite2, 
                                      logChanWrite3, commitChanWrite3, 
                                      nextChanWrite4, nextChanWrite5, 
                                      networkWrite6, iAmTheLeaderWrite4, 
                                      termWrite3, logChanWrite4, 
                                      commitChanWrite4, networkWrite7, 
                                      nextChanWrite6, iAmTheLeaderWrite5, 
                                      termWrite4, logChanWrite5, 
                                      commitChanWrite5, lastmsgWrite2, 
                                      networkWrite8, appliedWrite4, 
                                      nextChanWrite7, iAmTheLeaderWrite6, 
                                      termWrite5, logChanWrite6, 
                                      commitChanWrite6, iAmTheLeaderWrite7, 
                                      lastmsgWrite3, networkWrite9, 
                                      appliedWrite5, nextChanWrite8, 
                                      termWrite6, logChanWrite7, 
                                      commitChanWrite7, networkWrite10, 
                                      inputWrite1, logChanWrite8, 
                                      nextChanWrite9, commitChanWrite8, 
                                      appliedWrite6, iAmTheLeaderWrite8, 
                                      lastmsgWrite4, termWrite7, 
                                      iAmTheLeaderRead0, timerWrite, 
                                      nextIndexInRead, termRead, logInRead, 
                                      logInRead0, logInRead1, commitInRead, 
                                      networkWrite11, networkWrite12, 
                                      networkWrite13, timerWrite0, 
                                      networkWrite14, timerWrite1, 
                                      networkWrite15, msg_, null, heartbeatId, 
                                      proposerId, counter, requestId, proposal, 
                                      result_, result, learnerId, decided, 
                                      timeoutLocal, log, commitIndex, 
                                      lastApplied, nextIndex, matchIndex, 
                                      iterator, votes, value, msg, response, 
                                      msgs, index, next >>

MsgSwitch(self) == /\ pc[self] = "MsgSwitch"
                   /\ IF ((msg[self]).type) = (AppendEntries)
                         THEN /\ response' = [response EXCEPT ![self] = [sender |-> self, type |-> AppendEntriesResponse, term |-> currentTerm[self], granted |-> FALSE, entries |-> <<>>, prevIndex |-> NULL, prevTerm |-> NULL, commit |-> NULL]]
                              /\ IF (((msg[self]).term) >= (currentTerm[self])) /\ (((((msg[self]).prevIndex) > (0)) /\ ((Len(log[self])) > ((msg[self]).prevIndex))) \/ ((Term(log[self], (msg[self]).prevIndex)) # ((msg[self]).prevTerm)))
                                    THEN /\ Assert((state[self]) # (Leader), 
                                                   "Failure of assertion at line 761, column 37.")
                                         /\ log' = [log EXCEPT ![self] = SubSeq(log[self], 1, ((msg[self]).prevIndex) - (1))]
                                         /\ lastmsgWrite' = msg[self]
                                         /\ lastmsgWrite1' = lastmsgWrite'
                                         /\ lastSeen' = lastmsgWrite1'
                                         /\ pc' = [pc EXCEPT ![self] = "AESendResponse"]
                                         /\ UNCHANGED lastmsgWrite0
                                    ELSE /\ IF ((msg[self]).term) >= (currentTerm[self])
                                               THEN /\ IF (Len(log[self])) = ((msg[self]).prevIndex)
                                                          THEN /\ log' = [log EXCEPT ![self] = (log[self]) \o ((msg[self]).entries)]
                                                          ELSE /\ TRUE
                                                               /\ log' = log
                                                    /\ pc' = [pc EXCEPT ![self] = "AEValid"]
                                                    /\ UNCHANGED << lastSeen, 
                                                                    lastmsgWrite0, 
                                                                    lastmsgWrite1 >>
                                               ELSE /\ lastmsgWrite0' = lastSeen
                                                    /\ lastmsgWrite1' = lastmsgWrite0'
                                                    /\ lastSeen' = lastmsgWrite1'
                                                    /\ pc' = [pc EXCEPT ![self] = "AESendResponse"]
                                                    /\ log' = log
                                         /\ UNCHANGED lastmsgWrite
                              /\ UNCHANGED << learnedChan, 
                                              iAmTheLeaderAbstract, terms, 
                                              nexts, logs, commits, mailboxes, 
                                              iAmTheLeaderWrite1, termWrite0, 
                                              logChanWrite1, commitChanWrite1, 
                                              nextChanWrite2, 
                                              iAmTheLeaderWrite2, termWrite1, 
                                              logChanWrite2, commitChanWrite2, 
                                              nextChanWrite3, 
                                              iAmTheLeaderWrite3, termWrite2, 
                                              logChanWrite3, commitChanWrite3, 
                                              nextChanWrite4, nextChanWrite5, 
                                              networkWrite6, 
                                              iAmTheLeaderWrite4, termWrite3, 
                                              logChanWrite4, commitChanWrite4, 
                                              networkWrite7, nextChanWrite6, 
                                              iAmTheLeaderWrite5, termWrite4, 
                                              logChanWrite5, commitChanWrite5, 
                                              lastmsgWrite2, networkWrite8, 
                                              appliedWrite4, nextChanWrite7, 
                                              iAmTheLeaderWrite6, termWrite5, 
                                              logChanWrite6, commitChanWrite6, 
                                              votes >>
                         ELSE /\ IF ((msg[self]).type) = (RequestVote)
                                    THEN /\ response' = [response EXCEPT ![self] = [sender |-> self, type |-> RequestVoteResponse, term |-> currentTerm[self], granted |-> FALSE, entries |-> <<>>, prevIndex |-> NULL, prevTerm |-> NULL, commit |-> NULL]]
                                         /\ IF ((((votedFor[self]) = (NULL)) \/ ((votedFor[self]) = ((msg[self]).sender))) /\ (((msg[self]).term) >= (currentTerm[self]))) /\ ((((msg[self]).prevTerm) > (Term(log[self], Len(log[self])))) \/ ((((msg[self]).prevTerm) = (Term(log[self], Len(log[self])))) /\ (((msg[self]).prevIndex) >= (Len(log[self])))))
                                               THEN /\ pc' = [pc EXCEPT ![self] = "RVValid"]
                                               ELSE /\ pc' = [pc EXCEPT ![self] = "RVSendResponse"]
                                         /\ UNCHANGED << learnedChan, 
                                                         iAmTheLeaderAbstract, 
                                                         terms, lastSeen, 
                                                         nexts, logs, commits, 
                                                         mailboxes, 
                                                         iAmTheLeaderWrite1, 
                                                         termWrite0, 
                                                         logChanWrite1, 
                                                         commitChanWrite1, 
                                                         nextChanWrite2, 
                                                         iAmTheLeaderWrite2, 
                                                         termWrite1, 
                                                         logChanWrite2, 
                                                         commitChanWrite2, 
                                                         nextChanWrite3, 
                                                         iAmTheLeaderWrite3, 
                                                         termWrite2, 
                                                         logChanWrite3, 
                                                         commitChanWrite3, 
                                                         nextChanWrite4, 
                                                         nextChanWrite5, 
                                                         networkWrite6, 
                                                         iAmTheLeaderWrite4, 
                                                         termWrite3, 
                                                         logChanWrite4, 
                                                         commitChanWrite4, 
                                                         networkWrite7, 
                                                         nextChanWrite6, 
                                                         iAmTheLeaderWrite5, 
                                                         termWrite4, 
                                                         logChanWrite5, 
                                                         commitChanWrite5, 
                                                         lastmsgWrite2, 
                                                         networkWrite8, 
                                                         appliedWrite4, 
                                                         nextChanWrite7, 
                                                         iAmTheLeaderWrite6, 
                                                         termWrite5, 
                                                         logChanWrite6, 
                                                         commitChanWrite6, 
                                                         votes >>
                                    ELSE /\ IF ((((msg[self]).type) = (AppendEntriesResponse)) /\ (((msg[self]).term) = (currentTerm[self]))) /\ ((state[self]) = (Leader))
                                               THEN /\ pc' = [pc EXCEPT ![self] = "AERCheckGranted"]
                                                    /\ UNCHANGED << learnedChan, 
                                                                    iAmTheLeaderAbstract, 
                                                                    terms, 
                                                                    lastSeen, 
                                                                    nexts, 
                                                                    logs, 
                                                                    commits, 
                                                                    mailboxes, 
                                                                    iAmTheLeaderWrite1, 
                                                                    termWrite0, 
                                                                    logChanWrite1, 
                                                                    commitChanWrite1, 
                                                                    nextChanWrite2, 
                                                                    iAmTheLeaderWrite2, 
                                                                    termWrite1, 
                                                                    logChanWrite2, 
                                                                    commitChanWrite2, 
                                                                    nextChanWrite3, 
                                                                    iAmTheLeaderWrite3, 
                                                                    termWrite2, 
                                                                    logChanWrite3, 
                                                                    commitChanWrite3, 
                                                                    nextChanWrite4, 
                                                                    nextChanWrite5, 
                                                                    networkWrite6, 
                                                                    iAmTheLeaderWrite4, 
                                                                    termWrite3, 
                                                                    logChanWrite4, 
                                                                    commitChanWrite4, 
                                                                    networkWrite7, 
                                                                    nextChanWrite6, 
                                                                    iAmTheLeaderWrite5, 
                                                                    termWrite4, 
                                                                    logChanWrite5, 
                                                                    commitChanWrite5, 
                                                                    lastmsgWrite2, 
                                                                    networkWrite8, 
                                                                    appliedWrite4, 
                                                                    nextChanWrite7, 
                                                                    iAmTheLeaderWrite6, 
                                                                    termWrite5, 
                                                                    logChanWrite6, 
                                                                    commitChanWrite6, 
                                                                    votes >>
                                               ELSE /\ IF ((((msg[self]).type) = (RequestVoteResponse)) /\ (((msg[self]).term) = (currentTerm[self]))) /\ ((state[self]) = (Candidate))
                                                          THEN /\ IF (msg[self]).granted
                                                                     THEN /\ votes' = [votes EXCEPT ![self][msg[self].term] = (votes[self][(msg[self]).term]) \union ({(msg[self]).sender})]
                                                                          /\ IF ((Cardinality(votes'[self][(msg[self]).term])) * (2)) > (Cardinality(Servers))
                                                                                THEN /\ pc' = [pc EXCEPT ![self] = "BecomeLeader"]
                                                                                     /\ UNCHANGED << learnedChan, 
                                                                                                     iAmTheLeaderAbstract, 
                                                                                                     terms, 
                                                                                                     lastSeen, 
                                                                                                     nexts, 
                                                                                                     logs, 
                                                                                                     commits, 
                                                                                                     mailboxes, 
                                                                                                     iAmTheLeaderWrite1, 
                                                                                                     termWrite0, 
                                                                                                     logChanWrite1, 
                                                                                                     commitChanWrite1, 
                                                                                                     nextChanWrite2, 
                                                                                                     iAmTheLeaderWrite2, 
                                                                                                     termWrite1, 
                                                                                                     logChanWrite2, 
                                                                                                     commitChanWrite2, 
                                                                                                     nextChanWrite3, 
                                                                                                     iAmTheLeaderWrite3, 
                                                                                                     termWrite2, 
                                                                                                     logChanWrite3, 
                                                                                                     commitChanWrite3, 
                                                                                                     nextChanWrite4, 
                                                                                                     nextChanWrite5, 
                                                                                                     networkWrite6, 
                                                                                                     iAmTheLeaderWrite4, 
                                                                                                     termWrite3, 
                                                                                                     logChanWrite4, 
                                                                                                     commitChanWrite4, 
                                                                                                     networkWrite7, 
                                                                                                     nextChanWrite6, 
                                                                                                     iAmTheLeaderWrite5, 
                                                                                                     termWrite4, 
                                                                                                     logChanWrite5, 
                                                                                                     commitChanWrite5, 
                                                                                                     lastmsgWrite2, 
                                                                                                     networkWrite8, 
                                                                                                     appliedWrite4, 
                                                                                                     nextChanWrite7, 
                                                                                                     iAmTheLeaderWrite6, 
                                                                                                     termWrite5, 
                                                                                                     logChanWrite6, 
                                                                                                     commitChanWrite6 >>
                                                                                ELSE /\ iAmTheLeaderWrite1' = iAmTheLeaderAbstract
                                                                                     /\ termWrite0' = terms
                                                                                     /\ logChanWrite1' = logs
                                                                                     /\ commitChanWrite1' = commits
                                                                                     /\ nextChanWrite2' = nexts
                                                                                     /\ iAmTheLeaderWrite2' = iAmTheLeaderWrite1'
                                                                                     /\ termWrite1' = termWrite0'
                                                                                     /\ logChanWrite2' = logChanWrite1'
                                                                                     /\ commitChanWrite2' = commitChanWrite1'
                                                                                     /\ nextChanWrite3' = nextChanWrite2'
                                                                                     /\ iAmTheLeaderWrite3' = iAmTheLeaderWrite2'
                                                                                     /\ termWrite2' = termWrite1'
                                                                                     /\ logChanWrite3' = logChanWrite2'
                                                                                     /\ commitChanWrite3' = commitChanWrite2'
                                                                                     /\ nextChanWrite4' = nextChanWrite3'
                                                                                     /\ nextChanWrite5' = nextChanWrite4'
                                                                                     /\ networkWrite6' = mailboxes
                                                                                     /\ iAmTheLeaderWrite4' = iAmTheLeaderWrite3'
                                                                                     /\ termWrite3' = termWrite2'
                                                                                     /\ logChanWrite4' = logChanWrite3'
                                                                                     /\ commitChanWrite4' = commitChanWrite3'
                                                                                     /\ networkWrite7' = networkWrite6'
                                                                                     /\ nextChanWrite6' = nextChanWrite5'
                                                                                     /\ iAmTheLeaderWrite5' = iAmTheLeaderWrite4'
                                                                                     /\ termWrite4' = termWrite3'
                                                                                     /\ logChanWrite5' = logChanWrite4'
                                                                                     /\ commitChanWrite5' = commitChanWrite4'
                                                                                     /\ lastmsgWrite2' = lastSeen
                                                                                     /\ networkWrite8' = networkWrite7'
                                                                                     /\ appliedWrite4' = learnedChan
                                                                                     /\ nextChanWrite7' = nextChanWrite6'
                                                                                     /\ iAmTheLeaderWrite6' = iAmTheLeaderWrite5'
                                                                                     /\ termWrite5' = termWrite4'
                                                                                     /\ logChanWrite6' = logChanWrite5'
                                                                                     /\ commitChanWrite6' = commitChanWrite5'
                                                                                     /\ mailboxes' = networkWrite8'
                                                                                     /\ learnedChan' = appliedWrite4'
                                                                                     /\ iAmTheLeaderAbstract' = iAmTheLeaderWrite6'
                                                                                     /\ terms' = termWrite5'
                                                                                     /\ lastSeen' = lastmsgWrite2'
                                                                                     /\ nexts' = nextChanWrite7'
                                                                                     /\ logs' = logChanWrite6'
                                                                                     /\ commits' = commitChanWrite6'
                                                                                     /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                                                                     ELSE /\ iAmTheLeaderWrite2' = iAmTheLeaderAbstract
                                                                          /\ termWrite1' = terms
                                                                          /\ logChanWrite2' = logs
                                                                          /\ commitChanWrite2' = commits
                                                                          /\ nextChanWrite3' = nexts
                                                                          /\ iAmTheLeaderWrite3' = iAmTheLeaderWrite2'
                                                                          /\ termWrite2' = termWrite1'
                                                                          /\ logChanWrite3' = logChanWrite2'
                                                                          /\ commitChanWrite3' = commitChanWrite2'
                                                                          /\ nextChanWrite4' = nextChanWrite3'
                                                                          /\ nextChanWrite5' = nextChanWrite4'
                                                                          /\ networkWrite6' = mailboxes
                                                                          /\ iAmTheLeaderWrite4' = iAmTheLeaderWrite3'
                                                                          /\ termWrite3' = termWrite2'
                                                                          /\ logChanWrite4' = logChanWrite3'
                                                                          /\ commitChanWrite4' = commitChanWrite3'
                                                                          /\ networkWrite7' = networkWrite6'
                                                                          /\ nextChanWrite6' = nextChanWrite5'
                                                                          /\ iAmTheLeaderWrite5' = iAmTheLeaderWrite4'
                                                                          /\ termWrite4' = termWrite3'
                                                                          /\ logChanWrite5' = logChanWrite4'
                                                                          /\ commitChanWrite5' = commitChanWrite4'
                                                                          /\ lastmsgWrite2' = lastSeen
                                                                          /\ networkWrite8' = networkWrite7'
                                                                          /\ appliedWrite4' = learnedChan
                                                                          /\ nextChanWrite7' = nextChanWrite6'
                                                                          /\ iAmTheLeaderWrite6' = iAmTheLeaderWrite5'
                                                                          /\ termWrite5' = termWrite4'
                                                                          /\ logChanWrite6' = logChanWrite5'
                                                                          /\ commitChanWrite6' = commitChanWrite5'
                                                                          /\ mailboxes' = networkWrite8'
                                                                          /\ learnedChan' = appliedWrite4'
                                                                          /\ iAmTheLeaderAbstract' = iAmTheLeaderWrite6'
                                                                          /\ terms' = termWrite5'
                                                                          /\ lastSeen' = lastmsgWrite2'
                                                                          /\ nexts' = nextChanWrite7'
                                                                          /\ logs' = logChanWrite6'
                                                                          /\ commits' = commitChanWrite6'
                                                                          /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                                                                          /\ UNCHANGED << iAmTheLeaderWrite1, 
                                                                                          termWrite0, 
                                                                                          logChanWrite1, 
                                                                                          commitChanWrite1, 
                                                                                          nextChanWrite2, 
                                                                                          votes >>
                                                          ELSE /\ iAmTheLeaderWrite3' = iAmTheLeaderAbstract
                                                               /\ termWrite2' = terms
                                                               /\ logChanWrite3' = logs
                                                               /\ commitChanWrite3' = commits
                                                               /\ nextChanWrite4' = nexts
                                                               /\ nextChanWrite5' = nextChanWrite4'
                                                               /\ networkWrite6' = mailboxes
                                                               /\ iAmTheLeaderWrite4' = iAmTheLeaderWrite3'
                                                               /\ termWrite3' = termWrite2'
                                                               /\ logChanWrite4' = logChanWrite3'
                                                               /\ commitChanWrite4' = commitChanWrite3'
                                                               /\ networkWrite7' = networkWrite6'
                                                               /\ nextChanWrite6' = nextChanWrite5'
                                                               /\ iAmTheLeaderWrite5' = iAmTheLeaderWrite4'
                                                               /\ termWrite4' = termWrite3'
                                                               /\ logChanWrite5' = logChanWrite4'
                                                               /\ commitChanWrite5' = commitChanWrite4'
                                                               /\ lastmsgWrite2' = lastSeen
                                                               /\ networkWrite8' = networkWrite7'
                                                               /\ appliedWrite4' = learnedChan
                                                               /\ nextChanWrite7' = nextChanWrite6'
                                                               /\ iAmTheLeaderWrite6' = iAmTheLeaderWrite5'
                                                               /\ termWrite5' = termWrite4'
                                                               /\ logChanWrite6' = logChanWrite5'
                                                               /\ commitChanWrite6' = commitChanWrite5'
                                                               /\ mailboxes' = networkWrite8'
                                                               /\ learnedChan' = appliedWrite4'
                                                               /\ iAmTheLeaderAbstract' = iAmTheLeaderWrite6'
                                                               /\ terms' = termWrite5'
                                                               /\ lastSeen' = lastmsgWrite2'
                                                               /\ nexts' = nextChanWrite7'
                                                               /\ logs' = logChanWrite6'
                                                               /\ commits' = commitChanWrite6'
                                                               /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                                                               /\ UNCHANGED << iAmTheLeaderWrite1, 
                                                                               termWrite0, 
                                                                               logChanWrite1, 
                                                                               commitChanWrite1, 
                                                                               nextChanWrite2, 
                                                                               iAmTheLeaderWrite2, 
                                                                               termWrite1, 
                                                                               logChanWrite2, 
                                                                               commitChanWrite2, 
                                                                               nextChanWrite3, 
                                                                               votes >>
                                         /\ UNCHANGED response
                              /\ UNCHANGED << lastmsgWrite, lastmsgWrite0, 
                                              lastmsgWrite1, log >>
                   /\ UNCHANGED << values, requestSet, raftLayerChan, kvClient, 
                                   idAbstract, database, frequency, 
                                   requestsRead, requestsWrite, 
                                   iAmTheLeaderRead, proposerChanWrite, 
                                   raftChanRead, raftChanWrite, upstreamWrite, 
                                   proposerChanWrite0, raftChanWrite0, 
                                   upstreamWrite0, requestsWrite0, 
                                   proposerChanWrite1, raftChanWrite1, 
                                   upstreamWrite1, learnerChanRead, 
                                   learnerChanWrite, kvIdRead, dbWrite, 
                                   dbWrite0, kvIdRead0, kvIdRead1, dbRead, 
                                   kvIdRead2, requestServiceWrite, 
                                   requestServiceWrite0, learnerChanWrite0, 
                                   dbWrite1, requestServiceWrite1, timeoutRead, 
                                   networkWrite, networkWrite0, networkWrite1, 
                                   inputRead, inputWrite, logChanWrite, 
                                   nextChanWrite, commitChanWrite, 
                                   appliedWrite, appliedWrite0, networkWrite2, 
                                   networkWrite3, inputWrite0, logChanWrite0, 
                                   nextChanWrite0, commitChanWrite0, 
                                   appliedWrite1, networkWrite4, networkRead, 
                                   iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                   ifResult, appliedWrite2, appliedWrite3, 
                                   ifResult0, nextChanWrite1, networkWrite5, 
                                   termWrite, iAmTheLeaderWrite7, 
                                   lastmsgWrite3, networkWrite9, appliedWrite5, 
                                   nextChanWrite8, termWrite6, logChanWrite7, 
                                   commitChanWrite7, networkWrite10, 
                                   inputWrite1, logChanWrite8, nextChanWrite9, 
                                   commitChanWrite8, appliedWrite6, 
                                   iAmTheLeaderWrite8, lastmsgWrite4, 
                                   termWrite7, iAmTheLeaderRead0, timerWrite, 
                                   nextIndexInRead, termRead, logInRead, 
                                   logInRead0, logInRead1, commitInRead, 
                                   networkWrite11, networkWrite12, 
                                   networkWrite13, timerWrite0, networkWrite14, 
                                   timerWrite1, networkWrite15, msg_, null, 
                                   heartbeatId, proposerId, counter, requestId, 
                                   proposal, result_, result, learnerId, 
                                   decided, timeoutLocal, currentTerm, 
                                   votedFor, state, commitIndex, lastApplied, 
                                   nextIndex, matchIndex, iterator, value, msg, 
                                   msgs, index, next >>

AESendResponse(self) == /\ pc[self] = "AESendResponse"
                        /\ networkWrite' = [mailboxes EXCEPT ![(msg[self]).sender] = Append(mailboxes[(msg[self]).sender], response[self])]
                        /\ IF ((msg[self]).commit) > (commitIndex[self])
                              THEN /\ IF ((msg[self]).commit) < (Len(log[self]))
                                         THEN /\ ifResult' = (msg[self]).commit
                                         ELSE /\ ifResult' = Len(log[self])
                                   /\ commitIndex' = [commitIndex EXCEPT ![self] = ifResult']
                                   /\ mailboxes' = networkWrite'
                                   /\ pc' = [pc EXCEPT ![self] = "AEApplyCommitted"]
                                   /\ UNCHANGED << learnedChan, appliedWrite3 >>
                              ELSE /\ appliedWrite3' = learnedChan
                                   /\ mailboxes' = networkWrite'
                                   /\ learnedChan' = appliedWrite3'
                                   /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                                   /\ UNCHANGED << ifResult, commitIndex >>
                        /\ UNCHANGED << values, requestSet, raftLayerChan, 
                                        kvClient, idAbstract, database, 
                                        iAmTheLeaderAbstract, frequency, terms, 
                                        lastSeen, nexts, logs, commits, 
                                        requestsRead, requestsWrite, 
                                        iAmTheLeaderRead, proposerChanWrite, 
                                        raftChanRead, raftChanWrite, 
                                        upstreamWrite, proposerChanWrite0, 
                                        raftChanWrite0, upstreamWrite0, 
                                        requestsWrite0, proposerChanWrite1, 
                                        raftChanWrite1, upstreamWrite1, 
                                        learnerChanRead, learnerChanWrite, 
                                        kvIdRead, dbWrite, dbWrite0, kvIdRead0, 
                                        kvIdRead1, dbRead, kvIdRead2, 
                                        requestServiceWrite, 
                                        requestServiceWrite0, 
                                        learnerChanWrite0, dbWrite1, 
                                        requestServiceWrite1, timeoutRead, 
                                        networkWrite0, networkWrite1, 
                                        inputRead, inputWrite, logChanWrite, 
                                        nextChanWrite, commitChanWrite, 
                                        appliedWrite, appliedWrite0, 
                                        networkWrite2, networkWrite3, 
                                        inputWrite0, logChanWrite0, 
                                        nextChanWrite0, commitChanWrite0, 
                                        appliedWrite1, networkWrite4, 
                                        networkRead, iAmTheLeaderWrite, 
                                        iAmTheLeaderWrite0, lastmsgWrite, 
                                        lastmsgWrite0, lastmsgWrite1, 
                                        appliedWrite2, ifResult0, 
                                        nextChanWrite1, networkWrite5, 
                                        termWrite, iAmTheLeaderWrite1, 
                                        termWrite0, logChanWrite1, 
                                        commitChanWrite1, nextChanWrite2, 
                                        iAmTheLeaderWrite2, termWrite1, 
                                        logChanWrite2, commitChanWrite2, 
                                        nextChanWrite3, iAmTheLeaderWrite3, 
                                        termWrite2, logChanWrite3, 
                                        commitChanWrite3, nextChanWrite4, 
                                        nextChanWrite5, networkWrite6, 
                                        iAmTheLeaderWrite4, termWrite3, 
                                        logChanWrite4, commitChanWrite4, 
                                        networkWrite7, nextChanWrite6, 
                                        iAmTheLeaderWrite5, termWrite4, 
                                        logChanWrite5, commitChanWrite5, 
                                        lastmsgWrite2, networkWrite8, 
                                        appliedWrite4, nextChanWrite7, 
                                        iAmTheLeaderWrite6, termWrite5, 
                                        logChanWrite6, commitChanWrite6, 
                                        iAmTheLeaderWrite7, lastmsgWrite3, 
                                        networkWrite9, appliedWrite5, 
                                        nextChanWrite8, termWrite6, 
                                        logChanWrite7, commitChanWrite7, 
                                        networkWrite10, inputWrite1, 
                                        logChanWrite8, nextChanWrite9, 
                                        commitChanWrite8, appliedWrite6, 
                                        iAmTheLeaderWrite8, lastmsgWrite4, 
                                        termWrite7, iAmTheLeaderRead0, 
                                        timerWrite, nextIndexInRead, termRead, 
                                        logInRead, logInRead0, logInRead1, 
                                        commitInRead, networkWrite11, 
                                        networkWrite12, networkWrite13, 
                                        timerWrite0, networkWrite14, 
                                        timerWrite1, networkWrite15, msg_, 
                                        null, heartbeatId, proposerId, counter, 
                                        requestId, proposal, result_, result, 
                                        learnerId, decided, timeoutLocal, 
                                        currentTerm, votedFor, log, state, 
                                        lastApplied, nextIndex, matchIndex, 
                                        iterator, votes, value, msg, response, 
                                        msgs, index, next >>

AEApplyCommitted(self) == /\ pc[self] = "AEApplyCommitted"
                          /\ IF (lastApplied[self]) < (commitIndex[self])
                                THEN /\ lastApplied' = [lastApplied EXCEPT ![self] = (lastApplied[self]) + (1)]
                                     /\ (Len(learnedChan[self])) < (BUFFER_SIZE)
                                     /\ appliedWrite' = [learnedChan EXCEPT ![self] = Append(learnedChan[self], (log[self][lastApplied'[self]]).val)]
                                     /\ appliedWrite2' = appliedWrite'
                                     /\ learnedChan' = appliedWrite2'
                                     /\ pc' = [pc EXCEPT ![self] = "AEApplyCommitted"]
                                ELSE /\ appliedWrite2' = learnedChan
                                     /\ learnedChan' = appliedWrite2'
                                     /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                                     /\ UNCHANGED << appliedWrite, lastApplied >>
                          /\ UNCHANGED << values, requestSet, raftLayerChan, 
                                          kvClient, idAbstract, database, 
                                          iAmTheLeaderAbstract, frequency, 
                                          terms, lastSeen, nexts, logs, 
                                          commits, mailboxes, requestsRead, 
                                          requestsWrite, iAmTheLeaderRead, 
                                          proposerChanWrite, raftChanRead, 
                                          raftChanWrite, upstreamWrite, 
                                          proposerChanWrite0, raftChanWrite0, 
                                          upstreamWrite0, requestsWrite0, 
                                          proposerChanWrite1, raftChanWrite1, 
                                          upstreamWrite1, learnerChanRead, 
                                          learnerChanWrite, kvIdRead, dbWrite, 
                                          dbWrite0, kvIdRead0, kvIdRead1, 
                                          dbRead, kvIdRead2, 
                                          requestServiceWrite, 
                                          requestServiceWrite0, 
                                          learnerChanWrite0, dbWrite1, 
                                          requestServiceWrite1, timeoutRead, 
                                          networkWrite, networkWrite0, 
                                          networkWrite1, inputRead, inputWrite, 
                                          logChanWrite, nextChanWrite, 
                                          commitChanWrite, appliedWrite0, 
                                          networkWrite2, networkWrite3, 
                                          inputWrite0, logChanWrite0, 
                                          nextChanWrite0, commitChanWrite0, 
                                          appliedWrite1, networkWrite4, 
                                          networkRead, iAmTheLeaderWrite, 
                                          iAmTheLeaderWrite0, lastmsgWrite, 
                                          lastmsgWrite0, lastmsgWrite1, 
                                          ifResult, appliedWrite3, ifResult0, 
                                          nextChanWrite1, networkWrite5, 
                                          termWrite, iAmTheLeaderWrite1, 
                                          termWrite0, logChanWrite1, 
                                          commitChanWrite1, nextChanWrite2, 
                                          iAmTheLeaderWrite2, termWrite1, 
                                          logChanWrite2, commitChanWrite2, 
                                          nextChanWrite3, iAmTheLeaderWrite3, 
                                          termWrite2, logChanWrite3, 
                                          commitChanWrite3, nextChanWrite4, 
                                          nextChanWrite5, networkWrite6, 
                                          iAmTheLeaderWrite4, termWrite3, 
                                          logChanWrite4, commitChanWrite4, 
                                          networkWrite7, nextChanWrite6, 
                                          iAmTheLeaderWrite5, termWrite4, 
                                          logChanWrite5, commitChanWrite5, 
                                          lastmsgWrite2, networkWrite8, 
                                          appliedWrite4, nextChanWrite7, 
                                          iAmTheLeaderWrite6, termWrite5, 
                                          logChanWrite6, commitChanWrite6, 
                                          iAmTheLeaderWrite7, lastmsgWrite3, 
                                          networkWrite9, appliedWrite5, 
                                          nextChanWrite8, termWrite6, 
                                          logChanWrite7, commitChanWrite7, 
                                          networkWrite10, inputWrite1, 
                                          logChanWrite8, nextChanWrite9, 
                                          commitChanWrite8, appliedWrite6, 
                                          iAmTheLeaderWrite8, lastmsgWrite4, 
                                          termWrite7, iAmTheLeaderRead0, 
                                          timerWrite, nextIndexInRead, 
                                          termRead, logInRead, logInRead0, 
                                          logInRead1, commitInRead, 
                                          networkWrite11, networkWrite12, 
                                          networkWrite13, timerWrite0, 
                                          networkWrite14, timerWrite1, 
                                          networkWrite15, msg_, null, 
                                          heartbeatId, proposerId, counter, 
                                          requestId, proposal, result_, result, 
                                          learnerId, decided, timeoutLocal, 
                                          currentTerm, votedFor, log, state, 
                                          commitIndex, nextIndex, matchIndex, 
                                          iterator, votes, value, msg, 
                                          response, msgs, index, next >>

AEValid(self) == /\ pc[self] = "AEValid"
                 /\ response' = [response EXCEPT ![self] = [sender |-> self, type |-> AppendEntriesResponse, term |-> currentTerm[self], granted |-> TRUE, entries |-> <<>>, prevIndex |-> Len(log[self]), prevTerm |-> NULL, commit |-> NULL]]
                 /\ lastmsgWrite' = msg[self]
                 /\ lastSeen' = lastmsgWrite'
                 /\ pc' = [pc EXCEPT ![self] = "AESendResponse"]
                 /\ UNCHANGED << values, requestSet, learnedChan, 
                                 raftLayerChan, kvClient, idAbstract, database, 
                                 iAmTheLeaderAbstract, frequency, terms, nexts, 
                                 logs, commits, mailboxes, requestsRead, 
                                 requestsWrite, iAmTheLeaderRead, 
                                 proposerChanWrite, raftChanRead, 
                                 raftChanWrite, upstreamWrite, 
                                 proposerChanWrite0, raftChanWrite0, 
                                 upstreamWrite0, requestsWrite0, 
                                 proposerChanWrite1, raftChanWrite1, 
                                 upstreamWrite1, learnerChanRead, 
                                 learnerChanWrite, kvIdRead, dbWrite, dbWrite0, 
                                 kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
                                 requestServiceWrite, requestServiceWrite0, 
                                 learnerChanWrite0, dbWrite1, 
                                 requestServiceWrite1, timeoutRead, 
                                 networkWrite, networkWrite0, networkWrite1, 
                                 inputRead, inputWrite, logChanWrite, 
                                 nextChanWrite, commitChanWrite, appliedWrite, 
                                 appliedWrite0, networkWrite2, networkWrite3, 
                                 inputWrite0, logChanWrite0, nextChanWrite0, 
                                 commitChanWrite0, appliedWrite1, 
                                 networkWrite4, networkRead, iAmTheLeaderWrite, 
                                 iAmTheLeaderWrite0, lastmsgWrite0, 
                                 lastmsgWrite1, ifResult, appliedWrite2, 
                                 appliedWrite3, ifResult0, nextChanWrite1, 
                                 networkWrite5, termWrite, iAmTheLeaderWrite1, 
                                 termWrite0, logChanWrite1, commitChanWrite1, 
                                 nextChanWrite2, iAmTheLeaderWrite2, 
                                 termWrite1, logChanWrite2, commitChanWrite2, 
                                 nextChanWrite3, iAmTheLeaderWrite3, 
                                 termWrite2, logChanWrite3, commitChanWrite3, 
                                 nextChanWrite4, nextChanWrite5, networkWrite6, 
                                 iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
                                 commitChanWrite4, networkWrite7, 
                                 nextChanWrite6, iAmTheLeaderWrite5, 
                                 termWrite4, logChanWrite5, commitChanWrite5, 
                                 lastmsgWrite2, networkWrite8, appliedWrite4, 
                                 nextChanWrite7, iAmTheLeaderWrite6, 
                                 termWrite5, logChanWrite6, commitChanWrite6, 
                                 iAmTheLeaderWrite7, lastmsgWrite3, 
                                 networkWrite9, appliedWrite5, nextChanWrite8, 
                                 termWrite6, logChanWrite7, commitChanWrite7, 
                                 networkWrite10, inputWrite1, logChanWrite8, 
                                 nextChanWrite9, commitChanWrite8, 
                                 appliedWrite6, iAmTheLeaderWrite8, 
                                 lastmsgWrite4, termWrite7, iAmTheLeaderRead0, 
                                 timerWrite, nextIndexInRead, termRead, 
                                 logInRead, logInRead0, logInRead1, 
                                 commitInRead, networkWrite11, networkWrite12, 
                                 networkWrite13, timerWrite0, networkWrite14, 
                                 timerWrite1, networkWrite15, msg_, null, 
                                 heartbeatId, proposerId, counter, requestId, 
                                 proposal, result_, result, learnerId, decided, 
                                 timeoutLocal, currentTerm, votedFor, log, 
                                 state, commitIndex, lastApplied, nextIndex, 
                                 matchIndex, iterator, votes, value, msg, msgs, 
                                 index, next >>

RVSendResponse(self) == /\ pc[self] = "RVSendResponse"
                        /\ networkWrite' = [mailboxes EXCEPT ![(msg[self]).sender] = Append(mailboxes[(msg[self]).sender], response[self])]
                        /\ mailboxes' = networkWrite'
                        /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                        /\ UNCHANGED << values, requestSet, learnedChan, 
                                        raftLayerChan, kvClient, idAbstract, 
                                        database, iAmTheLeaderAbstract, 
                                        frequency, terms, lastSeen, nexts, 
                                        logs, commits, requestsRead, 
                                        requestsWrite, iAmTheLeaderRead, 
                                        proposerChanWrite, raftChanRead, 
                                        raftChanWrite, upstreamWrite, 
                                        proposerChanWrite0, raftChanWrite0, 
                                        upstreamWrite0, requestsWrite0, 
                                        proposerChanWrite1, raftChanWrite1, 
                                        upstreamWrite1, learnerChanRead, 
                                        learnerChanWrite, kvIdRead, dbWrite, 
                                        dbWrite0, kvIdRead0, kvIdRead1, dbRead, 
                                        kvIdRead2, requestServiceWrite, 
                                        requestServiceWrite0, 
                                        learnerChanWrite0, dbWrite1, 
                                        requestServiceWrite1, timeoutRead, 
                                        networkWrite0, networkWrite1, 
                                        inputRead, inputWrite, logChanWrite, 
                                        nextChanWrite, commitChanWrite, 
                                        appliedWrite, appliedWrite0, 
                                        networkWrite2, networkWrite3, 
                                        inputWrite0, logChanWrite0, 
                                        nextChanWrite0, commitChanWrite0, 
                                        appliedWrite1, networkWrite4, 
                                        networkRead, iAmTheLeaderWrite, 
                                        iAmTheLeaderWrite0, lastmsgWrite, 
                                        lastmsgWrite0, lastmsgWrite1, ifResult, 
                                        appliedWrite2, appliedWrite3, 
                                        ifResult0, nextChanWrite1, 
                                        networkWrite5, termWrite, 
                                        iAmTheLeaderWrite1, termWrite0, 
                                        logChanWrite1, commitChanWrite1, 
                                        nextChanWrite2, iAmTheLeaderWrite2, 
                                        termWrite1, logChanWrite2, 
                                        commitChanWrite2, nextChanWrite3, 
                                        iAmTheLeaderWrite3, termWrite2, 
                                        logChanWrite3, commitChanWrite3, 
                                        nextChanWrite4, nextChanWrite5, 
                                        networkWrite6, iAmTheLeaderWrite4, 
                                        termWrite3, logChanWrite4, 
                                        commitChanWrite4, networkWrite7, 
                                        nextChanWrite6, iAmTheLeaderWrite5, 
                                        termWrite4, logChanWrite5, 
                                        commitChanWrite5, lastmsgWrite2, 
                                        networkWrite8, appliedWrite4, 
                                        nextChanWrite7, iAmTheLeaderWrite6, 
                                        termWrite5, logChanWrite6, 
                                        commitChanWrite6, iAmTheLeaderWrite7, 
                                        lastmsgWrite3, networkWrite9, 
                                        appliedWrite5, nextChanWrite8, 
                                        termWrite6, logChanWrite7, 
                                        commitChanWrite7, networkWrite10, 
                                        inputWrite1, logChanWrite8, 
                                        nextChanWrite9, commitChanWrite8, 
                                        appliedWrite6, iAmTheLeaderWrite8, 
                                        lastmsgWrite4, termWrite7, 
                                        iAmTheLeaderRead0, timerWrite, 
                                        nextIndexInRead, termRead, logInRead, 
                                        logInRead0, logInRead1, commitInRead, 
                                        networkWrite11, networkWrite12, 
                                        networkWrite13, timerWrite0, 
                                        networkWrite14, timerWrite1, 
                                        networkWrite15, msg_, null, 
                                        heartbeatId, proposerId, counter, 
                                        requestId, proposal, result_, result, 
                                        learnerId, decided, timeoutLocal, 
                                        currentTerm, votedFor, log, state, 
                                        commitIndex, lastApplied, nextIndex, 
                                        matchIndex, iterator, votes, value, 
                                        msg, response, msgs, index, next >>

RVValid(self) == /\ pc[self] = "RVValid"
                 /\ response' = [response EXCEPT ![self] = [sender |-> self, type |-> RequestVoteResponse, term |-> currentTerm[self], granted |-> TRUE, entries |-> <<>>, prevIndex |-> NULL, prevTerm |-> NULL, commit |-> NULL]]
                 /\ votedFor' = [votedFor EXCEPT ![self] = (msg[self]).sender]
                 /\ pc' = [pc EXCEPT ![self] = "RVSendResponse"]
                 /\ UNCHANGED << values, requestSet, learnedChan, 
                                 raftLayerChan, kvClient, idAbstract, database, 
                                 iAmTheLeaderAbstract, frequency, terms, 
                                 lastSeen, nexts, logs, commits, mailboxes, 
                                 requestsRead, requestsWrite, iAmTheLeaderRead, 
                                 proposerChanWrite, raftChanRead, 
                                 raftChanWrite, upstreamWrite, 
                                 proposerChanWrite0, raftChanWrite0, 
                                 upstreamWrite0, requestsWrite0, 
                                 proposerChanWrite1, raftChanWrite1, 
                                 upstreamWrite1, learnerChanRead, 
                                 learnerChanWrite, kvIdRead, dbWrite, dbWrite0, 
                                 kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
                                 requestServiceWrite, requestServiceWrite0, 
                                 learnerChanWrite0, dbWrite1, 
                                 requestServiceWrite1, timeoutRead, 
                                 networkWrite, networkWrite0, networkWrite1, 
                                 inputRead, inputWrite, logChanWrite, 
                                 nextChanWrite, commitChanWrite, appliedWrite, 
                                 appliedWrite0, networkWrite2, networkWrite3, 
                                 inputWrite0, logChanWrite0, nextChanWrite0, 
                                 commitChanWrite0, appliedWrite1, 
                                 networkWrite4, networkRead, iAmTheLeaderWrite, 
                                 iAmTheLeaderWrite0, lastmsgWrite, 
                                 lastmsgWrite0, lastmsgWrite1, ifResult, 
                                 appliedWrite2, appliedWrite3, ifResult0, 
                                 nextChanWrite1, networkWrite5, termWrite, 
                                 iAmTheLeaderWrite1, termWrite0, logChanWrite1, 
                                 commitChanWrite1, nextChanWrite2, 
                                 iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
                                 commitChanWrite2, nextChanWrite3, 
                                 iAmTheLeaderWrite3, termWrite2, logChanWrite3, 
                                 commitChanWrite3, nextChanWrite4, 
                                 nextChanWrite5, networkWrite6, 
                                 iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
                                 commitChanWrite4, networkWrite7, 
                                 nextChanWrite6, iAmTheLeaderWrite5, 
                                 termWrite4, logChanWrite5, commitChanWrite5, 
                                 lastmsgWrite2, networkWrite8, appliedWrite4, 
                                 nextChanWrite7, iAmTheLeaderWrite6, 
                                 termWrite5, logChanWrite6, commitChanWrite6, 
                                 iAmTheLeaderWrite7, lastmsgWrite3, 
                                 networkWrite9, appliedWrite5, nextChanWrite8, 
                                 termWrite6, logChanWrite7, commitChanWrite7, 
                                 networkWrite10, inputWrite1, logChanWrite8, 
                                 nextChanWrite9, commitChanWrite8, 
                                 appliedWrite6, iAmTheLeaderWrite8, 
                                 lastmsgWrite4, termWrite7, iAmTheLeaderRead0, 
                                 timerWrite, nextIndexInRead, termRead, 
                                 logInRead, logInRead0, logInRead1, 
                                 commitInRead, networkWrite11, networkWrite12, 
                                 networkWrite13, timerWrite0, networkWrite14, 
                                 timerWrite1, networkWrite15, msg_, null, 
                                 heartbeatId, proposerId, counter, requestId, 
                                 proposal, result_, result, learnerId, decided, 
                                 timeoutLocal, currentTerm, log, state, 
                                 commitIndex, lastApplied, nextIndex, 
                                 matchIndex, iterator, votes, value, msg, msgs, 
                                 index, next >>

AERCheckGranted(self) == /\ pc[self] = "AERCheckGranted"
                         /\ IF (msg[self]).granted
                               THEN /\ nextIndex' = [nextIndex EXCEPT ![self][msg[self].sender] = ((msg[self]).prevIndex) + (1)]
                                    /\ matchIndex' = [matchIndex EXCEPT ![self][msg[self].sender] = (msg[self]).prevIndex]
                                    /\ nextChanWrite' = [nexts EXCEPT ![self] = nextIndex'[self]]
                                    /\ nextChanWrite1' = nextChanWrite'
                                    /\ networkWrite5' = mailboxes
                                    /\ mailboxes' = networkWrite5'
                                    /\ nexts' = nextChanWrite1'
                                    /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                                    /\ UNCHANGED ifResult0
                               ELSE /\ IF ((nextIndex[self][(msg[self]).sender]) - (1)) > (1)
                                          THEN /\ ifResult0' = (nextIndex[self][(msg[self]).sender]) - (1)
                                          ELSE /\ ifResult0' = 1
                                    /\ nextIndex' = [nextIndex EXCEPT ![self][msg[self].sender] = ifResult0']
                                    /\ pc' = [pc EXCEPT ![self] = "RetryAppendEntry"]
                                    /\ UNCHANGED << nexts, mailboxes, 
                                                    nextChanWrite, 
                                                    nextChanWrite1, 
                                                    networkWrite5, matchIndex >>
                         /\ UNCHANGED << values, requestSet, learnedChan, 
                                         raftLayerChan, kvClient, idAbstract, 
                                         database, iAmTheLeaderAbstract, 
                                         frequency, terms, lastSeen, logs, 
                                         commits, requestsRead, requestsWrite, 
                                         iAmTheLeaderRead, proposerChanWrite, 
                                         raftChanRead, raftChanWrite, 
                                         upstreamWrite, proposerChanWrite0, 
                                         raftChanWrite0, upstreamWrite0, 
                                         requestsWrite0, proposerChanWrite1, 
                                         raftChanWrite1, upstreamWrite1, 
                                         learnerChanRead, learnerChanWrite, 
                                         kvIdRead, dbWrite, dbWrite0, 
                                         kvIdRead0, kvIdRead1, dbRead, 
                                         kvIdRead2, requestServiceWrite, 
                                         requestServiceWrite0, 
                                         learnerChanWrite0, dbWrite1, 
                                         requestServiceWrite1, timeoutRead, 
                                         networkWrite, networkWrite0, 
                                         networkWrite1, inputRead, inputWrite, 
                                         logChanWrite, commitChanWrite, 
                                         appliedWrite, appliedWrite0, 
                                         networkWrite2, networkWrite3, 
                                         inputWrite0, logChanWrite0, 
                                         nextChanWrite0, commitChanWrite0, 
                                         appliedWrite1, networkWrite4, 
                                         networkRead, iAmTheLeaderWrite, 
                                         iAmTheLeaderWrite0, lastmsgWrite, 
                                         lastmsgWrite0, lastmsgWrite1, 
                                         ifResult, appliedWrite2, 
                                         appliedWrite3, termWrite, 
                                         iAmTheLeaderWrite1, termWrite0, 
                                         logChanWrite1, commitChanWrite1, 
                                         nextChanWrite2, iAmTheLeaderWrite2, 
                                         termWrite1, logChanWrite2, 
                                         commitChanWrite2, nextChanWrite3, 
                                         iAmTheLeaderWrite3, termWrite2, 
                                         logChanWrite3, commitChanWrite3, 
                                         nextChanWrite4, nextChanWrite5, 
                                         networkWrite6, iAmTheLeaderWrite4, 
                                         termWrite3, logChanWrite4, 
                                         commitChanWrite4, networkWrite7, 
                                         nextChanWrite6, iAmTheLeaderWrite5, 
                                         termWrite4, logChanWrite5, 
                                         commitChanWrite5, lastmsgWrite2, 
                                         networkWrite8, appliedWrite4, 
                                         nextChanWrite7, iAmTheLeaderWrite6, 
                                         termWrite5, logChanWrite6, 
                                         commitChanWrite6, iAmTheLeaderWrite7, 
                                         lastmsgWrite3, networkWrite9, 
                                         appliedWrite5, nextChanWrite8, 
                                         termWrite6, logChanWrite7, 
                                         commitChanWrite7, networkWrite10, 
                                         inputWrite1, logChanWrite8, 
                                         nextChanWrite9, commitChanWrite8, 
                                         appliedWrite6, iAmTheLeaderWrite8, 
                                         lastmsgWrite4, termWrite7, 
                                         iAmTheLeaderRead0, timerWrite, 
                                         nextIndexInRead, termRead, logInRead, 
                                         logInRead0, logInRead1, commitInRead, 
                                         networkWrite11, networkWrite12, 
                                         networkWrite13, timerWrite0, 
                                         networkWrite14, timerWrite1, 
                                         networkWrite15, msg_, null, 
                                         heartbeatId, proposerId, counter, 
                                         requestId, proposal, result_, result, 
                                         learnerId, decided, timeoutLocal, 
                                         currentTerm, votedFor, log, state, 
                                         commitIndex, lastApplied, iterator, 
                                         votes, value, msg, response, msgs, 
                                         index, next >>

RetryAppendEntry(self) == /\ pc[self] = "RetryAppendEntry"
                          /\ networkWrite' = [mailboxes EXCEPT ![(msg[self]).sender] = Append(mailboxes[(msg[self]).sender], [sender |-> self, type |-> RequestVote, term |-> currentTerm[self], granted |-> FALSE, entries |-> SubSeq(log[self], nextIndex[self][(msg[self]).sender], Len(log[self])), prevIndex |-> (nextIndex[self][(msg[self]).sender]) - (1), prevTerm |-> Term(log[self], (nextIndex[self][(msg[self]).sender]) - (1)), commit |-> commitIndex[self]])]
                          /\ nextChanWrite' = [nexts EXCEPT ![self] = nextIndex[self]]
                          /\ mailboxes' = networkWrite'
                          /\ nexts' = nextChanWrite'
                          /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                          /\ UNCHANGED << values, requestSet, learnedChan, 
                                          raftLayerChan, kvClient, idAbstract, 
                                          database, iAmTheLeaderAbstract, 
                                          frequency, terms, lastSeen, logs, 
                                          commits, requestsRead, requestsWrite, 
                                          iAmTheLeaderRead, proposerChanWrite, 
                                          raftChanRead, raftChanWrite, 
                                          upstreamWrite, proposerChanWrite0, 
                                          raftChanWrite0, upstreamWrite0, 
                                          requestsWrite0, proposerChanWrite1, 
                                          raftChanWrite1, upstreamWrite1, 
                                          learnerChanRead, learnerChanWrite, 
                                          kvIdRead, dbWrite, dbWrite0, 
                                          kvIdRead0, kvIdRead1, dbRead, 
                                          kvIdRead2, requestServiceWrite, 
                                          requestServiceWrite0, 
                                          learnerChanWrite0, dbWrite1, 
                                          requestServiceWrite1, timeoutRead, 
                                          networkWrite0, networkWrite1, 
                                          inputRead, inputWrite, logChanWrite, 
                                          commitChanWrite, appliedWrite, 
                                          appliedWrite0, networkWrite2, 
                                          networkWrite3, inputWrite0, 
                                          logChanWrite0, nextChanWrite0, 
                                          commitChanWrite0, appliedWrite1, 
                                          networkWrite4, networkRead, 
                                          iAmTheLeaderWrite, 
                                          iAmTheLeaderWrite0, lastmsgWrite, 
                                          lastmsgWrite0, lastmsgWrite1, 
                                          ifResult, appliedWrite2, 
                                          appliedWrite3, ifResult0, 
                                          nextChanWrite1, networkWrite5, 
                                          termWrite, iAmTheLeaderWrite1, 
                                          termWrite0, logChanWrite1, 
                                          commitChanWrite1, nextChanWrite2, 
                                          iAmTheLeaderWrite2, termWrite1, 
                                          logChanWrite2, commitChanWrite2, 
                                          nextChanWrite3, iAmTheLeaderWrite3, 
                                          termWrite2, logChanWrite3, 
                                          commitChanWrite3, nextChanWrite4, 
                                          nextChanWrite5, networkWrite6, 
                                          iAmTheLeaderWrite4, termWrite3, 
                                          logChanWrite4, commitChanWrite4, 
                                          networkWrite7, nextChanWrite6, 
                                          iAmTheLeaderWrite5, termWrite4, 
                                          logChanWrite5, commitChanWrite5, 
                                          lastmsgWrite2, networkWrite8, 
                                          appliedWrite4, nextChanWrite7, 
                                          iAmTheLeaderWrite6, termWrite5, 
                                          logChanWrite6, commitChanWrite6, 
                                          iAmTheLeaderWrite7, lastmsgWrite3, 
                                          networkWrite9, appliedWrite5, 
                                          nextChanWrite8, termWrite6, 
                                          logChanWrite7, commitChanWrite7, 
                                          networkWrite10, inputWrite1, 
                                          logChanWrite8, nextChanWrite9, 
                                          commitChanWrite8, appliedWrite6, 
                                          iAmTheLeaderWrite8, lastmsgWrite4, 
                                          termWrite7, iAmTheLeaderRead0, 
                                          timerWrite, nextIndexInRead, 
                                          termRead, logInRead, logInRead0, 
                                          logInRead1, commitInRead, 
                                          networkWrite11, networkWrite12, 
                                          networkWrite13, timerWrite0, 
                                          networkWrite14, timerWrite1, 
                                          networkWrite15, msg_, null, 
                                          heartbeatId, proposerId, counter, 
                                          requestId, proposal, result_, result, 
                                          learnerId, decided, timeoutLocal, 
                                          currentTerm, votedFor, log, state, 
                                          commitIndex, lastApplied, nextIndex, 
                                          matchIndex, iterator, votes, value, 
                                          msg, response, msgs, index, next >>

BecomeLeader(self) == /\ pc[self] = "BecomeLeader"
                      /\ iAmTheLeaderWrite' = [iAmTheLeaderAbstract EXCEPT ![(self) + (NUM_NODES)] = TRUE]
                      /\ termWrite' = [terms EXCEPT ![self] = currentTerm[self]]
                      /\ logChanWrite' = [logs EXCEPT ![self] = log[self]]
                      /\ commitChanWrite' = [commits EXCEPT ![self] = commitIndex[self]]
                      /\ state' = [state EXCEPT ![self] = Leader]
                      /\ matchIndex' = [matchIndex EXCEPT ![self] = [s3 \in Servers |-> 0]]
                      /\ nextIndex' = [nextIndex EXCEPT ![self] = [s4 \in Servers |-> 1]]
                      /\ nextChanWrite' = [nexts EXCEPT ![self] = nextIndex'[self]]
                      /\ iAmTheLeaderAbstract' = iAmTheLeaderWrite'
                      /\ terms' = termWrite'
                      /\ nexts' = nextChanWrite'
                      /\ logs' = logChanWrite'
                      /\ commits' = commitChanWrite'
                      /\ pc' = [pc EXCEPT ![self] = "ProcessMsgs"]
                      /\ UNCHANGED << values, requestSet, learnedChan, 
                                      raftLayerChan, kvClient, idAbstract, 
                                      database, frequency, lastSeen, mailboxes, 
                                      requestsRead, requestsWrite, 
                                      iAmTheLeaderRead, proposerChanWrite, 
                                      raftChanRead, raftChanWrite, 
                                      upstreamWrite, proposerChanWrite0, 
                                      raftChanWrite0, upstreamWrite0, 
                                      requestsWrite0, proposerChanWrite1, 
                                      raftChanWrite1, upstreamWrite1, 
                                      learnerChanRead, learnerChanWrite, 
                                      kvIdRead, dbWrite, dbWrite0, kvIdRead0, 
                                      kvIdRead1, dbRead, kvIdRead2, 
                                      requestServiceWrite, 
                                      requestServiceWrite0, learnerChanWrite0, 
                                      dbWrite1, requestServiceWrite1, 
                                      timeoutRead, networkWrite, networkWrite0, 
                                      networkWrite1, inputRead, inputWrite, 
                                      appliedWrite, appliedWrite0, 
                                      networkWrite2, networkWrite3, 
                                      inputWrite0, logChanWrite0, 
                                      nextChanWrite0, commitChanWrite0, 
                                      appliedWrite1, networkWrite4, 
                                      networkRead, iAmTheLeaderWrite0, 
                                      lastmsgWrite, lastmsgWrite0, 
                                      lastmsgWrite1, ifResult, appliedWrite2, 
                                      appliedWrite3, ifResult0, nextChanWrite1, 
                                      networkWrite5, iAmTheLeaderWrite1, 
                                      termWrite0, logChanWrite1, 
                                      commitChanWrite1, nextChanWrite2, 
                                      iAmTheLeaderWrite2, termWrite1, 
                                      logChanWrite2, commitChanWrite2, 
                                      nextChanWrite3, iAmTheLeaderWrite3, 
                                      termWrite2, logChanWrite3, 
                                      commitChanWrite3, nextChanWrite4, 
                                      nextChanWrite5, networkWrite6, 
                                      iAmTheLeaderWrite4, termWrite3, 
                                      logChanWrite4, commitChanWrite4, 
                                      networkWrite7, nextChanWrite6, 
                                      iAmTheLeaderWrite5, termWrite4, 
                                      logChanWrite5, commitChanWrite5, 
                                      lastmsgWrite2, networkWrite8, 
                                      appliedWrite4, nextChanWrite7, 
                                      iAmTheLeaderWrite6, termWrite5, 
                                      logChanWrite6, commitChanWrite6, 
                                      iAmTheLeaderWrite7, lastmsgWrite3, 
                                      networkWrite9, appliedWrite5, 
                                      nextChanWrite8, termWrite6, 
                                      logChanWrite7, commitChanWrite7, 
                                      networkWrite10, inputWrite1, 
                                      logChanWrite8, nextChanWrite9, 
                                      commitChanWrite8, appliedWrite6, 
                                      iAmTheLeaderWrite8, lastmsgWrite4, 
                                      termWrite7, iAmTheLeaderRead0, 
                                      timerWrite, nextIndexInRead, termRead, 
                                      logInRead, logInRead0, logInRead1, 
                                      commitInRead, networkWrite11, 
                                      networkWrite12, networkWrite13, 
                                      timerWrite0, networkWrite14, timerWrite1, 
                                      networkWrite15, msg_, null, heartbeatId, 
                                      proposerId, counter, requestId, proposal, 
                                      result_, result, learnerId, decided, 
                                      timeoutLocal, currentTerm, votedFor, log, 
                                      commitIndex, lastApplied, iterator, 
                                      votes, value, msg, response, msgs, index, 
                                      next >>

server(self) == NodeLoop(self) \/ TimeoutCheck(self) \/ SendReqVotes(self)
                   \/ LeaderCheck(self) \/ GetVal(self)
                   \/ AdvanceIndex(self) \/ UpdateCommit(self)
                   \/ ApplyCommited(self) \/ SendAppendEntries(self)
                   \/ RecvMsg(self) \/ ProcessMsgs(self) \/ GetMsg(self)
                   \/ CheckMsgTerm(self) \/ MsgSwitch(self)
                   \/ AESendResponse(self) \/ AEApplyCommitted(self)
                   \/ AEValid(self) \/ RVSendResponse(self)
                   \/ RVValid(self) \/ AERCheckGranted(self)
                   \/ RetryAppendEntry(self) \/ BecomeLeader(self)

HBLoop(self) == /\ pc[self] = "HBLoop"
                /\ IF TRUE
                      THEN /\ pc' = [pc EXCEPT ![self] = "CheckHeartBeat"]
                           /\ UNCHANGED << frequency, mailboxes, timerWrite1, 
                                           networkWrite15 >>
                      ELSE /\ timerWrite1' = frequency
                           /\ networkWrite15' = mailboxes
                           /\ mailboxes' = networkWrite15'
                           /\ frequency' = timerWrite1'
                           /\ pc' = [pc EXCEPT ![self] = "Done"]
                /\ UNCHANGED << values, requestSet, learnedChan, raftLayerChan, 
                                kvClient, idAbstract, database, 
                                iAmTheLeaderAbstract, terms, lastSeen, nexts, 
                                logs, commits, requestsRead, requestsWrite, 
                                iAmTheLeaderRead, proposerChanWrite, 
                                raftChanRead, raftChanWrite, upstreamWrite, 
                                proposerChanWrite0, raftChanWrite0, 
                                upstreamWrite0, requestsWrite0, 
                                proposerChanWrite1, raftChanWrite1, 
                                upstreamWrite1, learnerChanRead, 
                                learnerChanWrite, kvIdRead, dbWrite, dbWrite0, 
                                kvIdRead0, kvIdRead1, dbRead, kvIdRead2, 
                                requestServiceWrite, requestServiceWrite0, 
                                learnerChanWrite0, dbWrite1, 
                                requestServiceWrite1, timeoutRead, 
                                networkWrite, networkWrite0, networkWrite1, 
                                inputRead, inputWrite, logChanWrite, 
                                nextChanWrite, commitChanWrite, appliedWrite, 
                                appliedWrite0, networkWrite2, networkWrite3, 
                                inputWrite0, logChanWrite0, nextChanWrite0, 
                                commitChanWrite0, appliedWrite1, networkWrite4, 
                                networkRead, iAmTheLeaderWrite, 
                                iAmTheLeaderWrite0, lastmsgWrite, 
                                lastmsgWrite0, lastmsgWrite1, ifResult, 
                                appliedWrite2, appliedWrite3, ifResult0, 
                                nextChanWrite1, networkWrite5, termWrite, 
                                iAmTheLeaderWrite1, termWrite0, logChanWrite1, 
                                commitChanWrite1, nextChanWrite2, 
                                iAmTheLeaderWrite2, termWrite1, logChanWrite2, 
                                commitChanWrite2, nextChanWrite3, 
                                iAmTheLeaderWrite3, termWrite2, logChanWrite3, 
                                commitChanWrite3, nextChanWrite4, 
                                nextChanWrite5, networkWrite6, 
                                iAmTheLeaderWrite4, termWrite3, logChanWrite4, 
                                commitChanWrite4, networkWrite7, 
                                nextChanWrite6, iAmTheLeaderWrite5, termWrite4, 
                                logChanWrite5, commitChanWrite5, lastmsgWrite2, 
                                networkWrite8, appliedWrite4, nextChanWrite7, 
                                iAmTheLeaderWrite6, termWrite5, logChanWrite6, 
                                commitChanWrite6, iAmTheLeaderWrite7, 
                                lastmsgWrite3, networkWrite9, appliedWrite5, 
                                nextChanWrite8, termWrite6, logChanWrite7, 
                                commitChanWrite7, networkWrite10, inputWrite1, 
                                logChanWrite8, nextChanWrite9, 
                                commitChanWrite8, appliedWrite6, 
                                iAmTheLeaderWrite8, lastmsgWrite4, termWrite7, 
                                iAmTheLeaderRead0, timerWrite, nextIndexInRead, 
                                termRead, logInRead, logInRead0, logInRead1, 
                                commitInRead, networkWrite11, networkWrite12, 
                                networkWrite13, timerWrite0, networkWrite14, 
                                msg_, null, heartbeatId, proposerId, counter, 
                                requestId, proposal, result_, result, 
                                learnerId, decided, timeoutLocal, currentTerm, 
                                votedFor, log, state, commitIndex, lastApplied, 
                                nextIndex, matchIndex, iterator, votes, value, 
                                msg, response, msgs, index, next >>

CheckHeartBeat(self) == /\ pc[self] = "CheckHeartBeat"
                        /\ iAmTheLeaderRead0' = iAmTheLeaderAbstract[self]
                        /\ iAmTheLeaderRead0'
                        /\ pc' = [pc EXCEPT ![self] = "SendHeartBeatLoop"]
                        /\ UNCHANGED << values, requestSet, learnedChan, 
                                        raftLayerChan, kvClient, idAbstract, 
                                        database, iAmTheLeaderAbstract, 
                                        frequency, terms, lastSeen, nexts, 
                                        logs, commits, mailboxes, requestsRead, 
                                        requestsWrite, iAmTheLeaderRead, 
                                        proposerChanWrite, raftChanRead, 
                                        raftChanWrite, upstreamWrite, 
                                        proposerChanWrite0, raftChanWrite0, 
                                        upstreamWrite0, requestsWrite0, 
                                        proposerChanWrite1, raftChanWrite1, 
                                        upstreamWrite1, learnerChanRead, 
                                        learnerChanWrite, kvIdRead, dbWrite, 
                                        dbWrite0, kvIdRead0, kvIdRead1, dbRead, 
                                        kvIdRead2, requestServiceWrite, 
                                        requestServiceWrite0, 
                                        learnerChanWrite0, dbWrite1, 
                                        requestServiceWrite1, timeoutRead, 
                                        networkWrite, networkWrite0, 
                                        networkWrite1, inputRead, inputWrite, 
                                        logChanWrite, nextChanWrite, 
                                        commitChanWrite, appliedWrite, 
                                        appliedWrite0, networkWrite2, 
                                        networkWrite3, inputWrite0, 
                                        logChanWrite0, nextChanWrite0, 
                                        commitChanWrite0, appliedWrite1, 
                                        networkWrite4, networkRead, 
                                        iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                        lastmsgWrite, lastmsgWrite0, 
                                        lastmsgWrite1, ifResult, appliedWrite2, 
                                        appliedWrite3, ifResult0, 
                                        nextChanWrite1, networkWrite5, 
                                        termWrite, iAmTheLeaderWrite1, 
                                        termWrite0, logChanWrite1, 
                                        commitChanWrite1, nextChanWrite2, 
                                        iAmTheLeaderWrite2, termWrite1, 
                                        logChanWrite2, commitChanWrite2, 
                                        nextChanWrite3, iAmTheLeaderWrite3, 
                                        termWrite2, logChanWrite3, 
                                        commitChanWrite3, nextChanWrite4, 
                                        nextChanWrite5, networkWrite6, 
                                        iAmTheLeaderWrite4, termWrite3, 
                                        logChanWrite4, commitChanWrite4, 
                                        networkWrite7, nextChanWrite6, 
                                        iAmTheLeaderWrite5, termWrite4, 
                                        logChanWrite5, commitChanWrite5, 
                                        lastmsgWrite2, networkWrite8, 
                                        appliedWrite4, nextChanWrite7, 
                                        iAmTheLeaderWrite6, termWrite5, 
                                        logChanWrite6, commitChanWrite6, 
                                        iAmTheLeaderWrite7, lastmsgWrite3, 
                                        networkWrite9, appliedWrite5, 
                                        nextChanWrite8, termWrite6, 
                                        logChanWrite7, commitChanWrite7, 
                                        networkWrite10, inputWrite1, 
                                        logChanWrite8, nextChanWrite9, 
                                        commitChanWrite8, appliedWrite6, 
                                        iAmTheLeaderWrite8, lastmsgWrite4, 
                                        termWrite7, timerWrite, 
                                        nextIndexInRead, termRead, logInRead, 
                                        logInRead0, logInRead1, commitInRead, 
                                        networkWrite11, networkWrite12, 
                                        networkWrite13, timerWrite0, 
                                        networkWrite14, timerWrite1, 
                                        networkWrite15, msg_, null, 
                                        heartbeatId, proposerId, counter, 
                                        requestId, proposal, result_, result, 
                                        learnerId, decided, timeoutLocal, 
                                        currentTerm, votedFor, log, state, 
                                        commitIndex, lastApplied, nextIndex, 
                                        matchIndex, iterator, votes, value, 
                                        msg, response, msgs, index, next >>

SendHeartBeatLoop(self) == /\ pc[self] = "SendHeartBeatLoop"
                           /\ iAmTheLeaderRead0' = iAmTheLeaderAbstract[self]
                           /\ IF iAmTheLeaderRead0'
                                 THEN /\ timerWrite' = HeartBeatFrequency
                                      /\ index' = [index EXCEPT ![self] = 0]
                                      /\ nextIndexInRead' = nexts[(self) - (NUM_NODES)]
                                      /\ next' = [next EXCEPT ![self] = nextIndexInRead']
                                      /\ frequency' = timerWrite'
                                      /\ pc' = [pc EXCEPT ![self] = "SendHeartBeats"]
                                      /\ UNCHANGED << mailboxes, timerWrite0, 
                                                      networkWrite14 >>
                                 ELSE /\ timerWrite0' = frequency
                                      /\ networkWrite14' = mailboxes
                                      /\ mailboxes' = networkWrite14'
                                      /\ frequency' = timerWrite0'
                                      /\ pc' = [pc EXCEPT ![self] = "HBLoop"]
                                      /\ UNCHANGED << timerWrite, 
                                                      nextIndexInRead, index, 
                                                      next >>
                           /\ UNCHANGED << values, requestSet, learnedChan, 
                                           raftLayerChan, kvClient, idAbstract, 
                                           database, iAmTheLeaderAbstract, 
                                           terms, lastSeen, nexts, logs, 
                                           commits, requestsRead, 
                                           requestsWrite, iAmTheLeaderRead, 
                                           proposerChanWrite, raftChanRead, 
                                           raftChanWrite, upstreamWrite, 
                                           proposerChanWrite0, raftChanWrite0, 
                                           upstreamWrite0, requestsWrite0, 
                                           proposerChanWrite1, raftChanWrite1, 
                                           upstreamWrite1, learnerChanRead, 
                                           learnerChanWrite, kvIdRead, dbWrite, 
                                           dbWrite0, kvIdRead0, kvIdRead1, 
                                           dbRead, kvIdRead2, 
                                           requestServiceWrite, 
                                           requestServiceWrite0, 
                                           learnerChanWrite0, dbWrite1, 
                                           requestServiceWrite1, timeoutRead, 
                                           networkWrite, networkWrite0, 
                                           networkWrite1, inputRead, 
                                           inputWrite, logChanWrite, 
                                           nextChanWrite, commitChanWrite, 
                                           appliedWrite, appliedWrite0, 
                                           networkWrite2, networkWrite3, 
                                           inputWrite0, logChanWrite0, 
                                           nextChanWrite0, commitChanWrite0, 
                                           appliedWrite1, networkWrite4, 
                                           networkRead, iAmTheLeaderWrite, 
                                           iAmTheLeaderWrite0, lastmsgWrite, 
                                           lastmsgWrite0, lastmsgWrite1, 
                                           ifResult, appliedWrite2, 
                                           appliedWrite3, ifResult0, 
                                           nextChanWrite1, networkWrite5, 
                                           termWrite, iAmTheLeaderWrite1, 
                                           termWrite0, logChanWrite1, 
                                           commitChanWrite1, nextChanWrite2, 
                                           iAmTheLeaderWrite2, termWrite1, 
                                           logChanWrite2, commitChanWrite2, 
                                           nextChanWrite3, iAmTheLeaderWrite3, 
                                           termWrite2, logChanWrite3, 
                                           commitChanWrite3, nextChanWrite4, 
                                           nextChanWrite5, networkWrite6, 
                                           iAmTheLeaderWrite4, termWrite3, 
                                           logChanWrite4, commitChanWrite4, 
                                           networkWrite7, nextChanWrite6, 
                                           iAmTheLeaderWrite5, termWrite4, 
                                           logChanWrite5, commitChanWrite5, 
                                           lastmsgWrite2, networkWrite8, 
                                           appliedWrite4, nextChanWrite7, 
                                           iAmTheLeaderWrite6, termWrite5, 
                                           logChanWrite6, commitChanWrite6, 
                                           iAmTheLeaderWrite7, lastmsgWrite3, 
                                           networkWrite9, appliedWrite5, 
                                           nextChanWrite8, termWrite6, 
                                           logChanWrite7, commitChanWrite7, 
                                           networkWrite10, inputWrite1, 
                                           logChanWrite8, nextChanWrite9, 
                                           commitChanWrite8, appliedWrite6, 
                                           iAmTheLeaderWrite8, lastmsgWrite4, 
                                           termWrite7, termRead, logInRead, 
                                           logInRead0, logInRead1, 
                                           commitInRead, networkWrite11, 
                                           networkWrite12, networkWrite13, 
                                           timerWrite1, networkWrite15, msg_, 
                                           null, heartbeatId, proposerId, 
                                           counter, requestId, proposal, 
                                           result_, result, learnerId, decided, 
                                           timeoutLocal, currentTerm, votedFor, 
                                           log, state, commitIndex, 
                                           lastApplied, nextIndex, matchIndex, 
                                           iterator, votes, value, msg, 
                                           response, msgs >>

SendHeartBeats(self) == /\ pc[self] = "SendHeartBeats"
                        /\ IF (index[self]) < (NUM_NODES)
                              THEN /\ IF (index[self]) # ((self) - (NUM_NODES))
                                         THEN /\ termRead' = terms[(self) - (NUM_NODES)]
                                              /\ logInRead' = logs[(self) - (NUM_NODES)]
                                              /\ logInRead0' = logs[(self) - (NUM_NODES)]
                                              /\ logInRead1' = logs[(self) - (NUM_NODES)]
                                              /\ commitInRead' = commits[(self) - (NUM_NODES)]
                                              /\ networkWrite11' = [mailboxes EXCEPT ![index[self]] = Append(mailboxes[index[self]], [sender |-> (self) - (NUM_NODES), type |-> AppendEntries, term |-> termRead', granted |-> FALSE, entries |-> SubSeq(logInRead', next[self][index[self]], Len(logInRead0')), prevIndex |-> (next[self][index[self]]) - (1), prevTerm |-> Term(logInRead1', (next[self][index[self]]) - (1)), commit |-> commitInRead'])]
                                              /\ networkWrite12' = networkWrite11'
                                         ELSE /\ networkWrite12' = mailboxes
                                              /\ UNCHANGED << termRead, 
                                                              logInRead, 
                                                              logInRead0, 
                                                              logInRead1, 
                                                              commitInRead, 
                                                              networkWrite11 >>
                                   /\ index' = [index EXCEPT ![self] = (index[self]) + (1)]
                                   /\ networkWrite13' = networkWrite12'
                                   /\ mailboxes' = networkWrite13'
                                   /\ pc' = [pc EXCEPT ![self] = "SendHeartBeats"]
                              ELSE /\ networkWrite13' = mailboxes
                                   /\ mailboxes' = networkWrite13'
                                   /\ pc' = [pc EXCEPT ![self] = "SendHeartBeatLoop"]
                                   /\ UNCHANGED << termRead, logInRead, 
                                                   logInRead0, logInRead1, 
                                                   commitInRead, 
                                                   networkWrite11, 
                                                   networkWrite12, index >>
                        /\ UNCHANGED << values, requestSet, learnedChan, 
                                        raftLayerChan, kvClient, idAbstract, 
                                        database, iAmTheLeaderAbstract, 
                                        frequency, terms, lastSeen, nexts, 
                                        logs, commits, requestsRead, 
                                        requestsWrite, iAmTheLeaderRead, 
                                        proposerChanWrite, raftChanRead, 
                                        raftChanWrite, upstreamWrite, 
                                        proposerChanWrite0, raftChanWrite0, 
                                        upstreamWrite0, requestsWrite0, 
                                        proposerChanWrite1, raftChanWrite1, 
                                        upstreamWrite1, learnerChanRead, 
                                        learnerChanWrite, kvIdRead, dbWrite, 
                                        dbWrite0, kvIdRead0, kvIdRead1, dbRead, 
                                        kvIdRead2, requestServiceWrite, 
                                        requestServiceWrite0, 
                                        learnerChanWrite0, dbWrite1, 
                                        requestServiceWrite1, timeoutRead, 
                                        networkWrite, networkWrite0, 
                                        networkWrite1, inputRead, inputWrite, 
                                        logChanWrite, nextChanWrite, 
                                        commitChanWrite, appliedWrite, 
                                        appliedWrite0, networkWrite2, 
                                        networkWrite3, inputWrite0, 
                                        logChanWrite0, nextChanWrite0, 
                                        commitChanWrite0, appliedWrite1, 
                                        networkWrite4, networkRead, 
                                        iAmTheLeaderWrite, iAmTheLeaderWrite0, 
                                        lastmsgWrite, lastmsgWrite0, 
                                        lastmsgWrite1, ifResult, appliedWrite2, 
                                        appliedWrite3, ifResult0, 
                                        nextChanWrite1, networkWrite5, 
                                        termWrite, iAmTheLeaderWrite1, 
                                        termWrite0, logChanWrite1, 
                                        commitChanWrite1, nextChanWrite2, 
                                        iAmTheLeaderWrite2, termWrite1, 
                                        logChanWrite2, commitChanWrite2, 
                                        nextChanWrite3, iAmTheLeaderWrite3, 
                                        termWrite2, logChanWrite3, 
                                        commitChanWrite3, nextChanWrite4, 
                                        nextChanWrite5, networkWrite6, 
                                        iAmTheLeaderWrite4, termWrite3, 
                                        logChanWrite4, commitChanWrite4, 
                                        networkWrite7, nextChanWrite6, 
                                        iAmTheLeaderWrite5, termWrite4, 
                                        logChanWrite5, commitChanWrite5, 
                                        lastmsgWrite2, networkWrite8, 
                                        appliedWrite4, nextChanWrite7, 
                                        iAmTheLeaderWrite6, termWrite5, 
                                        logChanWrite6, commitChanWrite6, 
                                        iAmTheLeaderWrite7, lastmsgWrite3, 
                                        networkWrite9, appliedWrite5, 
                                        nextChanWrite8, termWrite6, 
                                        logChanWrite7, commitChanWrite7, 
                                        networkWrite10, inputWrite1, 
                                        logChanWrite8, nextChanWrite9, 
                                        commitChanWrite8, appliedWrite6, 
                                        iAmTheLeaderWrite8, lastmsgWrite4, 
                                        termWrite7, iAmTheLeaderRead0, 
                                        timerWrite, nextIndexInRead, 
                                        timerWrite0, networkWrite14, 
                                        timerWrite1, networkWrite15, msg_, 
                                        null, heartbeatId, proposerId, counter, 
                                        requestId, proposal, result_, result, 
                                        learnerId, decided, timeoutLocal, 
                                        currentTerm, votedFor, log, state, 
                                        commitIndex, lastApplied, nextIndex, 
                                        matchIndex, iterator, votes, value, 
                                        msg, response, msgs, next >>

heartbeat(self) == HBLoop(self) \/ CheckHeartBeat(self)
                      \/ SendHeartBeatLoop(self) \/ SendHeartBeats(self)

Next == (\E self \in KVRequests: kvRequests(self))
           \/ (\E self \in KVManager: kvManager(self))
           \/ (\E self \in Servers: server(self))
           \/ (\E self \in Heartbeats: heartbeat(self))
           \/ (* Disjunct to prevent deadlock on termination *)
              ((\A self \in ProcSet: pc[self] = "Done") /\ UNCHANGED vars)

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in KVRequests : WF_vars(kvRequests(self))
        /\ \A self \in KVManager : WF_vars(kvManager(self))
        /\ \A self \in Servers : WF_vars(server(self))
        /\ \A self \in Heartbeats : WF_vars(heartbeat(self))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

\* Properties (from figure 3 on pg 6)
(*
- Election Safety: at most one leader can be elected in a given term.
- Leader Append-Only: a leader never overwrites or deletes entries in its log; it only appends new entries.
- Log Matching: if two logs contain an entry with the same index and term, then the logs are identical in all entries up through the given index.
- Leader Completeness: if a log entry is committed in a given term, then that entry will be present in the logs of the leaders for all higher-numbered terms.
- State Machine Safety: if a server has applied a log entry at a given index to its state machine, no other server will ever apply a different log entry for the same index.
*)
                                
ElectionSafety == \A i,j \in Servers :
                   (currentTerm[i] = currentTerm[j] /\ i # j) => state[i] # Leader \/ state[j] # Leader

\* Handled by assertion in code whenever log entries are being overwritten/deleted
LeaderAppendOnly == TRUE

LogMatching == \A i,j \in Servers :
                \A k \in 1..((IF Len(log[i]) < Len(log[j]) THEN Len(log[i]) ELSE Len(log[j]))-1):
                  log[i][k] = log[j][k] => \A l \in 1..k : log[i][l] = log[j][l]

LeaderCompleteness == \A i,j \in Servers:
                       state[j] = Leader => 
                        (Len(log[j]) >= commitIndex[i]
                        /\ \A k \in 1..commitIndex[i]: (log[j][k] = log[i][k]) \/ currentTerm[j] <= log[i][k].term)

\*StateMachineSafety == \A i,j \in Servers :
\*                            \A k \in 1..(IF lastApplied[i] < lastApplied[j] THEN lastApplied[i] ELSE lastApplied[j]):
\*                                appliedLocal[i][k] = appliedLocal[j][k]


\* Every KV node has a consistent database (this is only true if the keys used in PUT operations are distinct)
\* ConsistentDatabase == \A kv1, kv2 \in KVRequests, k \in PutSet :
\*                           database[kv1, k] # NULL /\ database[kv2, k] # NULL => database[kv1, k] = database[kv2, k]

ConsistentDatabase == \A kv1 \in KVRequests, k \in PutSet : database[kv1, k] = NULL_DB_VALUE \/ database[kv1, k] = k

\* Eventually the database of every node is populated with the associated value
\* All PUT operations performed are in the format: Put(key, key)
Progress == \A kv1, kv2 \in KVRequests, k \in PutSet : <>(database[kv1, k] = database[kv2, k])

\* Other properties (for sanity checking)
\*AppliedCorrect == \A n \in Servers, s \in 1..Slots : learnedChan[n][s].value # NULL

EventuallyLearned == \E s \in Servers : <>(Len(log[s])>0)

===============================================================================

\* Changelog:
\*
\* 2014-12-02:
\* - Fix AppendEntries to only send one entry at a time, as originally
\*   intended. Since SubSeq is inclusive, the upper bound of the range should
\*   have been nextIndex, not nextIndex + 1. Thanks to Igor Kovalenko for
\*   reporting the issue.
\* - Change matchIndex' to matchIndex (without the apostrophe) in
\*   AdvanceCommitIndex. This apostrophe was not intentional and perhaps
\*   confusing, though it makes no practical difference (matchIndex' equals
\*   matchIndex). Thanks to Hugues Evrard for reporting the issue.
\*
\* 2014-07-06:
\* - Version from PhD dissertation