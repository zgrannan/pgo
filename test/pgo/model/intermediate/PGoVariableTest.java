package pgo.model.intermediate;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import pcal.AST.PVarDecl;
import pcal.AST.VarDecl;
import pgo.model.intermediate.PGoPrimitiveType.PGoInt;
import pgo.model.intermediate.PGoPrimitiveType.PGoString;
import pcal.PcalParams;
import pcal.TLAToken;

public class PGoVariableTest {

	// Test basic conversion of variables to PGo equivalent
	@Test
	public void testConvertVarDecl() {
		VarDecl var = new VarDecl();
		var.var = "var";
		var.isEq = false;
		var.val = PcalParams.DefaultVarInit();

		PGoVariable p = PGoVariable.convert(generator, var);
		assertEquals(p.getName(), var.var);
		assertEquals(p.getIsSimpleAssignInit(), var.isEq);
		assertEquals(p.getPcalInitBlock().toString(), var.val.toString());

		var.var = "var2";
		p = PGoVariable.convert(generator, var);
		assertEquals(p.getName(), var.var);

		var.isEq = false;
		p = PGoVariable.convert(generator, var);
		assertEquals(p.getIsSimpleAssignInit(), var.isEq);

		var.val.addToken(new TLAToken("blah", 0, TLAToken.STRING));
		p = PGoVariable.convert(generator, var);
		assertEquals(p.getPcalInitBlock().toString(), var.val.toString());
	}

	@Test
	public void testConvertPVarDecl() {
		PVarDecl var = new PVarDecl();
		var.var = "var";
		var.val = PcalParams.DefaultVarInit();

		PGoVariable p = PGoVariable.convert(var, generator);
		assertEquals(p.getName(), var.var);
		assertEquals(p.getIsSimpleAssignInit(), var.isEq);
		assertEquals(p.getPcalInitBlock().toString(), var.val.toString());

		var.var = "var2";
		p = PGoVariable.convert(var, generator);
		assertEquals(p.getName(), var.var);

		var.val.addToken(new TLAToken("blah", 0, TLAToken.STRING));
		p = PGoVariable.convert(var, generator);
		assertEquals(p.getPcalInitBlock().toString(), var.val.toString());
	}

	@Test
	public void testConvertString() {
		String var = "var";
		PGoVariable p = PGoVariable.convert(generator, var);
		assertEquals(var, p.getName());
		assertTrue(p.getIsSimpleAssignInit());
		assertEquals(PcalParams.DefaultVarInit().toString(), p.getPcalInitBlock().toString());

		var = "var2";
		p = PGoVariable.convert(generator, var);
		assertEquals(var, p.getName());
		assertTrue(p.getIsSimpleAssignInit());
		assertEquals(PcalParams.DefaultVarInit().toString(), p.getPcalInitBlock().toString());
	}
	
	@Test
	public void testConvertType() {
		String var = "var";
		PGoType t = new PGoInt();
		PGoVariable p = PGoVariable.convert(var, t);
		assertEquals(var, p.getName());
		assertEquals(t, p.getType());
		assertTrue(p.getIsSimpleAssignInit());
		assertEquals(PcalParams.DefaultVarInit().toString(), p.getPcalInitBlock().toString());

		var = "var2";
		t = new PGoInt();
		p = PGoVariable.convert(var, t);
		assertEquals(var, p.getName());
		assertEquals(t, p.getType());
		assertTrue(p.getIsSimpleAssignInit());
		assertEquals(PcalParams.DefaultVarInit().toString(), p.getPcalInitBlock().toString());

		t = new PGoString();
		p = PGoVariable.convert(var, t);
		assertEquals(var, p.getName());
		assertEquals(t, p.getType());
		assertTrue(p.getIsSimpleAssignInit());
		assertEquals(PcalParams.DefaultVarInit().toString(), p.getPcalInitBlock().toString());
	}
}
