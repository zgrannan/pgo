package nestedcrdtimpl

import (
	"fmt"
	"github.com/UBC-NSS/pgo/distsys"
	"github.com/UBC-NSS/pgo/distsys/tla"
)

var _ = new(fmt.Stringer) // unconditionally prevent go compiler from reporting unused fmt import
var _ = distsys.ErrDone
var _ = tla.TLAValue{} // same, for tla

func MAX_NODE_ID(iface distsys.ArchetypeInterface) tla.TLAValue {
	return tla.TLAChoose(iface.GetConstant("NODE_IDS")(), func(element tla.TLAValue) bool {
		var n tla.TLAValue = element
		_ = n
		return tla.TLAQuantifiedUniversal([]tla.TLAValue{iface.GetConstant("NODE_IDS")()}, func(args []tla.TLAValue) bool {
			var n2 tla.TLAValue = args[0]
			_ = n2
			return tla.TLA_GreaterThanOrEqualSymbol(n, n2).AsBool()
		}).AsBool()
	})
}
func RESOURCE_OF(iface distsys.ArchetypeInterface, n0 tla.TLAValue) tla.TLAValue {
	return tla.TLA_PlusSymbol(MAX_NODE_ID(iface), n0)
}
func RESOURCE_IDS(iface distsys.ArchetypeInterface) tla.TLAValue {
	return tla.TLASetComprehension([]tla.TLAValue{iface.GetConstant("NODE_IDS")()}, func(args0 []tla.TLAValue) tla.TLAValue {
		var n1 tla.TLAValue = args0[0]
		_ = n1
		return RESOURCE_OF(iface, n1)
	})
}

var procTable = distsys.MakeMPCalProcTable()

var jumpTable = distsys.MakeMPCalJumpTable(
	distsys.MPCalCriticalSection{
		Name: "ATestRig.loop",
		Body: func(iface distsys.ArchetypeInterface) error {
			var err error
			_ = err
			i := iface.RequireArchetypeResource("ATestRig.i")
			iterCount := iface.RequireArchetypeResource("ATestRig.iterCount")
			crdt, err := iface.RequireArchetypeResourceRef("ATestRig.crdt")
			if err != nil {
				return err
			}
			countingCh, err := iface.RequireArchetypeResourceRef("ATestRig.countingCh")
			if err != nil {
				return err
			}
			var condition tla.TLAValue
			condition, err = iface.Read(i, []tla.TLAValue{})
			if err != nil {
				return err
			}
			var condition0 tla.TLAValue
			condition0, err = iface.Read(iterCount, []tla.TLAValue{})
			if err != nil {
				return err
			}
			if tla.TLA_LessThanSymbol(condition, condition0).AsBool() {
				var exprRead tla.TLAValue
				exprRead, err = iface.Read(i, []tla.TLAValue{})
				if err != nil {
					return err
				}
				err = iface.Write(i, []tla.TLAValue{}, tla.TLA_PlusSymbol(exprRead, tla.MakeTLANumber(1)))
				if err != nil {
					return err
				}
				err = iface.Write(crdt, []tla.TLAValue{}, tla.MakeTLANumber(1))
				if err != nil {
					return err
				}
				var exprRead0 tla.TLAValue
				exprRead0, err = iface.Read(crdt, []tla.TLAValue{})
				if err != nil {
					return err
				}
				err = iface.Write(countingCh, []tla.TLAValue{}, exprRead0)
				if err != nil {
					return err
				}
				return iface.Goto("ATestRig.loop")
			} else {
				return iface.Goto("ATestRig.endLoop")
			}
			// no statements
		},
	},
	distsys.MPCalCriticalSection{
		Name: "ATestRig.endLoop",
		Body: func(iface distsys.ArchetypeInterface) error {
			var err error
			_ = err
			countingCh0, err := iface.RequireArchetypeResourceRef("ATestRig.countingCh")
			if err != nil {
				return err
			}
			crdt1, err := iface.RequireArchetypeResourceRef("ATestRig.crdt")
			if err != nil {
				return err
			}
			var exprRead1 tla.TLAValue
			exprRead1, err = iface.Read(crdt1, []tla.TLAValue{})
			if err != nil {
				return err
			}
			err = iface.Write(countingCh0, []tla.TLAValue{}, exprRead1)
			if err != nil {
				return err
			}
			return iface.Goto("ATestRig.endLoop")
		},
	},
	distsys.MPCalCriticalSection{
		Name: "ATestRig.Done",
		Body: func(distsys.ArchetypeInterface) error {
			return distsys.ErrDone
		},
	},
	distsys.MPCalCriticalSection{
		Name: "ACRDTResource.receiveReq",
		Body: func(iface distsys.ArchetypeInterface) error {
			var err error
			_ = err
			req := iface.RequireArchetypeResource("ACRDTResource.req")
			in, err := iface.RequireArchetypeResourceRef("ACRDTResource.in")
			if err != nil {
				return err
			}
			criticalSectionInProgress := iface.RequireArchetypeResource("ACRDTResource.criticalSectionInProgress")
			readState := iface.RequireArchetypeResource("ACRDTResource.readState")
			state := iface.RequireArchetypeResource("ACRDTResource.state")
			out, err := iface.RequireArchetypeResourceRef("ACRDTResource.out")
			if err != nil {
				return err
			}
			remainingPeersToUpdate := iface.RequireArchetypeResource("ACRDTResource.remainingPeersToUpdate")
			peers, err := iface.RequireArchetypeResourceRef("ACRDTResource.peers")
			if err != nil {
				return err
			}
			network, err := iface.RequireArchetypeResourceRef("ACRDTResource.network")
			if err != nil {
				return err
			}
			switch iface.NextFairnessCounter("ACRDTResource.receiveReq.0", 3) {
			case 0:
				var exprRead2 tla.TLAValue
				exprRead2, err = iface.Read(in, []tla.TLAValue{iface.Self()})
				if err != nil {
					return err
				}
				err = iface.Write(req, []tla.TLAValue{}, exprRead2)
				if err != nil {
					return err
				}
				var condition1 tla.TLAValue
				condition1, err = iface.Read(req, []tla.TLAValue{})
				if err != nil {
					return err
				}
				if tla.TLA_EqualsSymbol(condition1.ApplyFunction(tla.MakeTLAString("tpe")), iface.GetConstant("READ_REQ")()).AsBool() {
					var condition2 tla.TLAValue
					condition2, err = iface.Read(criticalSectionInProgress, []tla.TLAValue{})
					if err != nil {
						return err
					}
					if tla.TLA_LogicalNotSymbol(condition2).AsBool() {
						var exprRead3 tla.TLAValue
						exprRead3, err = iface.Read(state, []tla.TLAValue{})
						if err != nil {
							return err
						}
						err = iface.Write(readState, []tla.TLAValue{}, exprRead3)
						if err != nil {
							return err
						}
						err = iface.Write(criticalSectionInProgress, []tla.TLAValue{}, tla.TLA_TRUE)
						if err != nil {
							return err
						}
						// no statements
					} else {
						// no statements
					}
					var exprRead4 tla.TLAValue
					exprRead4, err = iface.Read(readState, []tla.TLAValue{})
					if err != nil {
						return err
					}
					err = iface.Write(out, []tla.TLAValue{iface.Self()}, tla.MakeTLARecord([]tla.TLARecordField{
						{tla.MakeTLAString("tpe"), iface.GetConstant("READ_ACK")()},
						{tla.MakeTLAString("value"), iface.GetConstant("VIEW_FN")(exprRead4)},
					}))
					if err != nil {
						return err
					}
					// no statements
				} else {
					var condition3 tla.TLAValue
					condition3, err = iface.Read(req, []tla.TLAValue{})
					if err != nil {
						return err
					}
					if tla.TLA_EqualsSymbol(condition3.ApplyFunction(tla.MakeTLAString("tpe")), iface.GetConstant("WRITE_REQ")()).AsBool() {
						var condition4 tla.TLAValue
						condition4, err = iface.Read(criticalSectionInProgress, []tla.TLAValue{})
						if err != nil {
							return err
						}
						if tla.TLA_LogicalNotSymbol(condition4).AsBool() {
							var exprRead5 tla.TLAValue
							exprRead5, err = iface.Read(state, []tla.TLAValue{})
							if err != nil {
								return err
							}
							err = iface.Write(readState, []tla.TLAValue{}, exprRead5)
							if err != nil {
								return err
							}
							err = iface.Write(criticalSectionInProgress, []tla.TLAValue{}, tla.TLA_TRUE)
							if err != nil {
								return err
							}
							// no statements
						} else {
							// no statements
						}
						var exprRead6 tla.TLAValue
						exprRead6, err = iface.Read(readState, []tla.TLAValue{})
						if err != nil {
							return err
						}
						var exprRead7 tla.TLAValue
						exprRead7, err = iface.Read(req, []tla.TLAValue{})
						if err != nil {
							return err
						}
						err = iface.Write(readState, []tla.TLAValue{}, iface.GetConstant("UPDATE_FN")(iface.Self(), exprRead6, exprRead7.ApplyFunction(tla.MakeTLAString("value"))))
						if err != nil {
							return err
						}
						err = iface.Write(out, []tla.TLAValue{iface.Self()}, tla.MakeTLARecord([]tla.TLARecordField{
							{tla.MakeTLAString("tpe"), iface.GetConstant("WRITE_ACK")()},
						}))
						if err != nil {
							return err
						}
						// no statements
					} else {
						var condition5 tla.TLAValue
						condition5, err = iface.Read(req, []tla.TLAValue{})
						if err != nil {
							return err
						}
						if tla.TLA_EqualsSymbol(condition5.ApplyFunction(tla.MakeTLAString("tpe")), iface.GetConstant("ABORT_REQ")()).AsBool() {
							err = iface.Write(readState, []tla.TLAValue{}, iface.GetConstant("ZERO_VALUE")())
							if err != nil {
								return err
							}
							err = iface.Write(criticalSectionInProgress, []tla.TLAValue{}, tla.TLA_FALSE)
							if err != nil {
								return err
							}
							err = iface.Write(out, []tla.TLAValue{iface.Self()}, tla.MakeTLARecord([]tla.TLARecordField{
								{tla.MakeTLAString("tpe"), iface.GetConstant("ABORT_ACK")()},
							}))
							if err != nil {
								return err
							}
							// no statements
						} else {
							var condition6 tla.TLAValue
							condition6, err = iface.Read(req, []tla.TLAValue{})
							if err != nil {
								return err
							}
							if tla.TLA_EqualsSymbol(condition6.ApplyFunction(tla.MakeTLAString("tpe")), iface.GetConstant("PRECOMMIT_REQ")()).AsBool() {
								err = iface.Write(out, []tla.TLAValue{iface.Self()}, tla.MakeTLARecord([]tla.TLARecordField{
									{tla.MakeTLAString("tpe"), iface.GetConstant("PRECOMMIT_ACK")()},
								}))
								if err != nil {
									return err
								}
								// no statements
							} else {
								var condition7 tla.TLAValue
								condition7, err = iface.Read(req, []tla.TLAValue{})
								if err != nil {
									return err
								}
								if tla.TLA_EqualsSymbol(condition7.ApplyFunction(tla.MakeTLAString("tpe")), iface.GetConstant("COMMIT_REQ")()).AsBool() {
									var condition8 tla.TLAValue
									condition8, err = iface.Read(state, []tla.TLAValue{})
									if err != nil {
										return err
									}
									var condition9 tla.TLAValue
									condition9, err = iface.Read(readState, []tla.TLAValue{})
									if err != nil {
										return err
									}
									if tla.TLA_NotEqualsSymbol(condition8, condition9).AsBool() {
										var exprRead8 tla.TLAValue
										exprRead8, err = iface.Read(peers, []tla.TLAValue{})
										if err != nil {
											return err
										}
										err = iface.Write(remainingPeersToUpdate, []tla.TLAValue{}, exprRead8)
										if err != nil {
											return err
										}
										// no statements
									} else {
										// no statements
									}
									var exprRead9 tla.TLAValue
									exprRead9, err = iface.Read(state, []tla.TLAValue{})
									if err != nil {
										return err
									}
									var exprRead10 tla.TLAValue
									exprRead10, err = iface.Read(readState, []tla.TLAValue{})
									if err != nil {
										return err
									}
									err = iface.Write(state, []tla.TLAValue{}, iface.GetConstant("COMBINE_FN")(exprRead9, exprRead10))
									if err != nil {
										return err
									}
									err = iface.Write(readState, []tla.TLAValue{}, iface.GetConstant("ZERO_VALUE")())
									if err != nil {
										return err
									}
									err = iface.Write(criticalSectionInProgress, []tla.TLAValue{}, tla.TLA_FALSE)
									if err != nil {
										return err
									}
									err = iface.Write(out, []tla.TLAValue{iface.Self()}, tla.MakeTLARecord([]tla.TLARecordField{
										{tla.MakeTLAString("tpe"), iface.GetConstant("COMMIT_ACK")()},
									}))
									if err != nil {
										return err
									}
									// no statements
								} else {
									if !tla.TLA_FALSE.AsBool() {
										return fmt.Errorf("%w: FALSE", distsys.ErrAssertionFailed)
									}
									// no statements
								}
								// no statements
							}
							// no statements
						}
						// no statements
					}
					// no statements
				}
				// no statements
			case 1:
				var updateValRead tla.TLAValue
				updateValRead, err = iface.Read(network, []tla.TLAValue{iface.Self()})
				if err != nil {
					return err
				}
				var updateVal tla.TLAValue = updateValRead
				var exprRead11 tla.TLAValue
				exprRead11, err = iface.Read(state, []tla.TLAValue{})
				if err != nil {
					return err
				}
				err = iface.Write(state, []tla.TLAValue{}, iface.GetConstant("COMBINE_FN")(updateVal, exprRead11))
				if err != nil {
					return err
				}
				// no statements
				// no statements
			case 2:
				var targetRead tla.TLAValue
				targetRead, err = iface.Read(remainingPeersToUpdate, []tla.TLAValue{})
				if err != nil {
					return err
				}
				if targetRead.AsSet().Len() == 0 {
					return distsys.ErrCriticalSectionAborted
				}
				var target tla.TLAValue = targetRead.SelectElement(iface.NextFairnessCounter("ACRDTResource.receiveReq.1", uint(targetRead.AsSet().Len())))
				var exprRead12 tla.TLAValue
				exprRead12, err = iface.Read(state, []tla.TLAValue{})
				if err != nil {
					return err
				}
				err = iface.Write(network, []tla.TLAValue{target}, exprRead12)
				if err != nil {
					return err
				}
				var exprRead13 tla.TLAValue
				exprRead13, err = iface.Read(remainingPeersToUpdate, []tla.TLAValue{})
				if err != nil {
					return err
				}
				err = iface.Write(remainingPeersToUpdate, []tla.TLAValue{}, tla.TLA_BackslashSymbol(exprRead13, tla.MakeTLASet(target)))
				if err != nil {
					return err
				}
				// no statements
				// no statements
			default:
				panic("current branch of either matches no code paths!")
			}
			return iface.Goto("ACRDTResource.receiveReq")
		},
	},
	distsys.MPCalCriticalSection{
		Name: "ACRDTResource.Done",
		Body: func(distsys.ArchetypeInterface) error {
			return distsys.ErrDone
		},
	},
)

var ATestRig = distsys.MPCalArchetype{
	Name:              "ATestRig",
	Label:             "ATestRig.loop",
	RequiredRefParams: []string{"ATestRig.crdt", "ATestRig.countingCh"},
	RequiredValParams: []string{"ATestRig.iterCount"},
	JumpTable:         jumpTable,
	ProcTable:         procTable,
	PreAmble: func(iface distsys.ArchetypeInterface) {
		iface.EnsureArchetypeResourceLocal("ATestRig.i", tla.MakeTLANumber(0))
	},
}

var ACRDTResource = distsys.MPCalArchetype{
	Name:              "ACRDTResource",
	Label:             "ACRDTResource.receiveReq",
	RequiredRefParams: []string{"ACRDTResource.in", "ACRDTResource.out", "ACRDTResource.network", "ACRDTResource.peers"},
	RequiredValParams: []string{},
	JumpTable:         jumpTable,
	ProcTable:         procTable,
	PreAmble: func(iface distsys.ArchetypeInterface) {
		iface.EnsureArchetypeResourceLocal("ACRDTResource.remainingPeersToUpdate", tla.MakeTLASet())
		iface.EnsureArchetypeResourceLocal("ACRDTResource.req", tla.TLAValue{})
		iface.EnsureArchetypeResourceLocal("ACRDTResource.criticalSectionInProgress", tla.TLA_FALSE)
		iface.EnsureArchetypeResourceLocal("ACRDTResource.state", iface.GetConstant("ZERO_VALUE")())
		iface.EnsureArchetypeResourceLocal("ACRDTResource.readState", iface.ReadArchetypeResourceLocal("ACRDTResource.state"))
	},
}
