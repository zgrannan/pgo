package pgo.trans.intermediate;

import java.util.Vector;

import pcal.AST;
import pcal.AST.Macro;
import pcal.AST.Multiprocess;
import pcal.AST.Procedure;
import pcal.AST.Process;
import pcal.AST.Uniprocess;
import pcal.AST.VarDecl;
import pcal.TLAExpr;
import pgo.model.intermediate.PGoFunction;
import pgo.model.intermediate.PGoRoutineInit;
import pgo.model.intermediate.PGoVariable;
import pgo.parser.PGoAnnotationParser;
import pgo.parser.PGoParseException;
import pgo.parser.PcalParser.ParsedPcal;
import pgo.trans.PGoTransException;

/**
 * Makes initial pass over the AST to generate the basic intermediate
 * structures, which may not be fully populated (ie, type inference is not
 * completed).
 *
 */
public class PGoTransStageInitParse {

	// The PlusCal AST to parse
	private AST ast;
	// intermediate data, which is filled with annotation information and data
	// from the PlusCal ast
	PGoTransIntermediateData data;

	public PGoTransStageInitParse(ParsedPcal parsed) throws PGoTransException, PGoParseException {
		data = new PGoTransIntermediateData();
		this.ast = parsed.getAST();
		this.data.annots = new PGoAnnotationParser(parsed.getPGoAnnotations());

		trans();
	}

	/**
	 * Translates the PlusCal AST to the first stage intermediate representation
	 * 
	 * @throws PGoTransException
	 *             on error
	 */
	private void trans() throws PGoTransException {
		if (ast instanceof Uniprocess) {
			data.isMultiProcess = false;
			trans((Uniprocess) ast);
		} else if (ast instanceof Multiprocess) {
			data.isMultiProcess = true;
			trans((Multiprocess) ast);
		} else {
			throw new PGoTransException("Error: PlusCal algorithm must be one of uniprocess or multiprocess");
		}
	}

	/**
	 * Class for Multiprocess AST and Uniprocess AST that creates a common way
	 * of operating on them. This class will keep all the common fields of the
	 * Multiprocess and Uniprocess AST
	 * 
	 */
	private class BaseAlgAST extends AST {

		public String name = "";
		public Vector decls = null; // of VarDecl
		public TLAExpr defs = null;
		public Vector macros = null; // of Macro
		public Vector prcds = null; // of Procedure

		public BaseAlgAST(Multiprocess ast) {
			this.name = ast.name;
			this.decls = ast.decls;
			this.defs = ast.defs;
			this.macros = ast.macros;
			this.prcds = ast.prcds;
		}

		public BaseAlgAST(Uniprocess ast) {
			this.name = ast.name;
			this.decls = ast.decls;
			this.defs = ast.defs;
			this.macros = ast.macros;
			this.prcds = ast.prcds;
		}
	}

	/**
	 * Translates the PlusCal AST of a multiprocess algorithm into first stage
	 * intermediate representation, setting the corresponding fields of this
	 * class
	 * 
	 * @param ast
	 */
	private void trans(Multiprocess ast) {
		transCommon(new BaseAlgAST(ast));

		// TODO eventually we want to support a process as a goroutine and a
		// networked process. For now we just do goroutines
		for (Process p : (Vector<Process>) ast.procs) {
			PGoFunction f = PGoFunction.convert(p);
			data.funcs.put(f.getName(), f);

			data.goroutines.put(f.getName(), PGoRoutineInit.convert(p));
		}
	}

	/**
	 * Translates the PlusCal AST of a uniprocess algorithm into first stage
	 * intermediate representation, setting the corresponding fields of this
	 * class
	 * 
	 * @param ast
	 */
	private void trans(Uniprocess ast) {
		transCommon(new BaseAlgAST(ast));

		data.mainBlock.addAll(ast.body);
	}

	/**
	 * Translates the common parts of Multiprocess and Uniprocess (called now
	 * BaseAST)
	 * PlusCal algorithm into first stage intermediate representation, setting
	 * the
	 * corresponding fields of this class.
	 * 
	 * Common parts are: name, variable declarations, tla definitions, and
	 * macros, procedures
	 * 
	 * @param ast
	 *            BaseAlgAST representation of types Uniprocess or Multiprocess
	 */
	private void transCommon(BaseAlgAST ast) {
		this.data.algName = ast.name;
		for (VarDecl var : (Vector<VarDecl>) ast.decls) {
			PGoVariable pvar = PGoVariable.convert(var);
			data.globals.put(pvar.getName(), pvar);
		}
		this.data.tlaExpr = ast.defs;
		for (Macro m : (Vector<Macro>) ast.macros) {
			PGoFunction f = PGoFunction.convert(m);
			data.funcs.put(f.getName(), f);
		}
		for (Procedure m : (Vector<Procedure>) ast.prcds) {
			PGoFunction f = PGoFunction.convert(m);
			data.funcs.put(f.getName(), f);
		}
	}

}
