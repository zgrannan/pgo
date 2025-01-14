package proxy_test

import (
	"fmt"
	"log"
	"testing"
	"time"

	"github.com/UBC-NSS/pgo/distsys/tla"

	"example.org/proxy"
	"github.com/UBC-NSS/pgo/distsys"
	"github.com/UBC-NSS/pgo/distsys/resources"
)

const numRequests = 10
const testTimeout = 2 * time.Second

func TestNUM_NODES(t *testing.T) {
	ctx := distsys.NewMPCalContextWithoutArchetype(
		distsys.DefineConstantValue("NUM_SERVERS", tla.MakeTLANumber(2)),
		distsys.DefineConstantValue("NUM_CLIENTS", tla.MakeTLANumber(3)))
	res := proxy.NUM_NODES(ctx.IFace())
	if res.AsNumber() != 6 {
		t.Fatalf("wrong NUM_NODES results, expected 6, got %v", res)
	}
}

func getNetworkMaker(self tla.TLAValue, constantsIFace distsys.ArchetypeInterface) distsys.ArchetypeResourceMaker {
	return resources.TCPMailboxesArchetypeResourceMaker(
		func(idx tla.TLAValue) (resources.TCPMailboxKind, string) {
			aid := idx.AsTuple().Get(0).(tla.TLAValue).AsNumber()
			msgType := idx.AsTuple().Get(1).(tla.TLAValue).AsNumber()
			kind := resources.TCPMailboxesRemote
			if aid == self.AsNumber() {
				kind = resources.TCPMailboxesLocal
			}
			msgTypeSize := proxy.MSG_TYP_SET(constantsIFace).AsSet().Len()
			portNum := 8000 + (aid-1)*int32(msgTypeSize) + (msgType - 1)
			addr := fmt.Sprintf("localhost:%d", portNum)
			return kind, addr
		},
	)
}

func runArchetype(done <-chan struct{}, ctx *distsys.MPCalContext, fn func() error) error {
	go func() {
		<-done
		if cerr := ctx.Close(); cerr != nil {
			log.Println(cerr)
		}
	}()
	err := fn()
	if cerr := ctx.Close(); cerr != nil {
		log.Println(cerr)
	}
	if err == distsys.ErrContextClosed {
		return nil
	}
	return err
}

const monAddr = "localhost:9000"

func genClientRun() func() tla.TLAValue {
	cnt := 0
	return func() tla.TLAValue {
		res := tla.TLA_FALSE
		if cnt < numRequests {
			res = tla.TLA_TRUE
		}
		cnt++
		return res
	}
}

func withConstantConfigs(configFns ...distsys.MPCalContextConfigFn) []distsys.MPCalContextConfigFn {
	var constantConfigs = []distsys.MPCalContextConfigFn{
		distsys.DefineConstantValue("NUM_SERVERS", tla.MakeTLANumber(2)),
		distsys.DefineConstantValue("NUM_CLIENTS", tla.MakeTLANumber(1)),
		distsys.DefineConstantValue("EXPLORE_FAIL", tla.TLA_FALSE),
		distsys.DefineConstantOperator("CLIENT_RUN", genClientRun()),
	}

	var result []distsys.MPCalContextConfigFn
	result = append(result, constantConfigs...)
	result = append(result, configFns...)
	return result
}

var constantsIFace = distsys.NewMPCalContextWithoutArchetype(withConstantConfigs()...).IFace()

func runServer(done <-chan struct{}, self tla.TLAValue, mon *resources.Monitor) error {
	ctx := distsys.NewMPCalContext(self, proxy.AServer, withConstantConfigs(
		distsys.EnsureArchetypeRefParam("net", getNetworkMaker(self, constantsIFace)),
		distsys.EnsureArchetypeRefParam("fd", resources.PlaceHolderResourceMaker()),
		distsys.EnsureArchetypeRefParam("netEnabled", resources.PlaceHolderResourceMaker()))...)
	return runArchetype(done, ctx, func() error {
		return mon.RunArchetype(ctx)
	})
}

func runClient(done <-chan struct{}, self tla.TLAValue, outputChannel chan tla.TLAValue) error {
	ctx := distsys.NewMPCalContext(self, proxy.AClient, withConstantConfigs(
		distsys.EnsureArchetypeRefParam("net", getNetworkMaker(self, constantsIFace)),
		distsys.EnsureArchetypeRefParam("output", resources.OutputChannelResourceMaker(outputChannel)))...)
	return runArchetype(done, ctx, ctx.Run)
}

func runProxy(done <-chan struct{}, self tla.TLAValue) error {
	ctx := distsys.NewMPCalContext(self, proxy.AProxy, withConstantConfigs(
		distsys.EnsureArchetypeRefParam("net", getNetworkMaker(self, constantsIFace)),
		distsys.EnsureArchetypeRefParam("fd", resources.FailureDetectorResourceMaker(
			func(idx tla.TLAValue) string {
				return monAddr
			},
			resources.WithFailureDetectorPullInterval(time.Millisecond*500),
			resources.WithFailureDetectorTimeout(time.Second*3000),
		)))...)
	return runArchetype(done, ctx, ctx.Run)
}

func setupMonitor() *resources.Monitor {
	mon := resources.NewMonitor(monAddr)
	go func() {
		if err := mon.ListenAndServe(); err != nil {
			log.Fatal(err)
		}
	}()
	return mon
}

func TestProxy_AllServersRunning(t *testing.T) {
	const numRunningArchetypes = 4

	outputChannel := make(chan tla.TLAValue)
	mon := setupMonitor()
	done := make(chan struct{})
	errs := make(chan error)
	go func() {
		errs <- runServer(done, tla.MakeTLANumber(1), mon)
	}()
	go func() {
		errs <- runServer(done, tla.MakeTLANumber(2), mon)
	}()
	go func() {
		errs <- runProxy(done, tla.MakeTLANumber(4))
	}()
	go func() {
		errs <- runClient(done, tla.MakeTLANumber(3), outputChannel)
	}()
	defer func() {
		for i := 0; i < numRunningArchetypes; i++ {
			done <- struct{}{}
		}
		for i := 0; i < numRunningArchetypes; i++ {
			err := <-errs
			if err != nil {
				t.Errorf("archetype error: %s", err)
			}
		}
		if err := mon.Close(); err != nil {
			log.Println(err)
		}
	}()

	for i := 0; i < numRequests; i++ {
		select {
		case resp := <-outputChannel:
			val, ok := resp.AsFunction().Get(tla.MakeTLAString("body"))
			if !ok {
				t.Fatalf("response body not found")
			}
			if !val.(tla.TLAValue).Equal(tla.MakeTLANumber(1)) {
				t.Fatalf("wrong response body, got %v, expected %v", val.(tla.TLAValue), tla.MakeTLANumber(1))
			}
		case <-time.After(testTimeout):
			t.Fatal("timeout")
		}
	}
}

func TestProxy_SecondServerRunning(t *testing.T) {
	const numRunningArchetypes = 3

	outputChannel := make(chan tla.TLAValue)
	mon := setupMonitor()
	done := make(chan struct{})
	errs := make(chan error)
	go func() {
		errs <- runServer(done, tla.MakeTLANumber(2), mon)
	}()
	go func() {
		errs <- runProxy(done, tla.MakeTLANumber(4))
	}()
	go func() {
		errs <- runClient(done, tla.MakeTLANumber(3), outputChannel)
	}()
	defer func() {
		for i := 0; i < numRunningArchetypes; i++ {
			done <- struct{}{}
		}
		for i := 0; i < numRunningArchetypes; i++ {
			err := <-errs
			if err != nil {
				t.Errorf("archetype error: %s", err)
			}
		}
		if err := mon.Close(); err != nil {
			log.Println(err)
		}
	}()

	for i := 0; i < numRequests; i++ {
		select {
		case resp := <-outputChannel:
			val, ok := resp.AsFunction().Get(tla.MakeTLAString("body"))
			if !ok {
				t.Fatalf("response body not found")
			}
			if !val.(tla.TLAValue).Equal(tla.MakeTLANumber(2)) {
				t.Fatalf("wrong response body, got %v, expected %v", val.(tla.TLAValue), tla.MakeTLANumber(2))
			}
		case <-time.After(testTimeout):
			t.Fatal("timeout")
		}
	}
}

func TestProxy_NoServerRunning(t *testing.T) {
	const numRunningArchetypes = 2

	outputChannel := make(chan tla.TLAValue)
	mon := setupMonitor()
	done := make(chan struct{})
	errs := make(chan error)
	go func() {
		errs <- runProxy(done, tla.MakeTLANumber(4))
	}()
	go func() {
		errs <- runClient(done, tla.MakeTLANumber(3), outputChannel)
	}()
	defer func() {
		for i := 0; i < numRunningArchetypes; i++ {
			done <- struct{}{}
		}
		for i := 0; i < numRunningArchetypes; i++ {
			err := <-errs
			if err != nil {
				t.Errorf("archetype error: %s", err)
			}
		}
		if err := mon.Close(); err != nil {
			log.Println(err)
		}
	}()

	for i := 0; i < numRequests; i++ {
		resp := <-outputChannel
		val, ok := resp.AsFunction().Get(tla.MakeTLAString("body"))
		if !ok {
			t.Fatalf("response body not found")
		}
		if !val.(tla.TLAValue).Equal(proxy.FAIL(constantsIFace)) {
			t.Fatalf("wrong response body, got %v, expected %v", val.(tla.TLAValue), proxy.FAIL(constantsIFace))
		}
	}
}
