package pgo.formatters;

import java.io.IOException;
import java.util.List;

import pgo.model.tla.PGoTLACaseArm;
import pgo.model.tla.PGoTLAExpression;
import pgo.model.tla.PGoTLAFunctionSubstitutionPair;
import pgo.model.tla.PGoTLAGeneralIdentifierPart;
import pgo.model.tla.PGoTLAIdentifier;
import pgo.model.tla.PGoTLAIdentifierOrTuple;
import pgo.model.tla.PGoTLAInstance.Remapping;
import pgo.model.tla.PGoTLAOpDecl;
import pgo.model.tla.PGoTLAQuantifierBound;
import pgo.model.tla.PGoTLARecordConstructor;
import pgo.model.tla.PGoTLARecordSet;
import pgo.model.tla.PGoTLASubstitutionKey;
import pgo.model.tla.PGoTLAUnit;
import pgo.model.tla.PGoTLANodeVisitor;

public class PGoTLANodeFormattingVisitor extends PGoTLANodeVisitor<Void, IOException> {
	
	IndentingWriter out;

	public PGoTLANodeFormattingVisitor(IndentingWriter out) {
		this.out = out;
	}

	@Override
	public Void visit(PGoTLAExpression pGoTLAExpression) throws IOException {
		pGoTLAExpression.accept(new PGoTLAExpressionFormattingVisitor(out));
		return null;
	}

	@Override
	public Void visit(PGoTLAUnit pGoTLAUnit) throws IOException {
		// TODO Auto-generated method stub
		return null;
	}

	@Override
	public Void visit(PGoTLACaseArm pGoTLACaseArm) throws IOException {
		// TODO Auto-generated method stub
		return null;
	}

	@Override
	public Void visit(PGoTLAOpDecl pGoTLAOpDecl) throws IOException {
		// TODO Auto-generated method stub
		return null;
	}

	@Override
	public Void visit(PGoTLASubstitutionKey pGoTLASubstitutionKey) throws IOException {
		out.write("[");
		FormattingTools.writeCommaSeparated(out, pGoTLASubstitutionKey.getIndices(), key -> {
			key.accept(new PGoTLAExpressionFormattingVisitor(out));
		});
		out.write("]");
		return null;
	}

	@Override
	public Void visit(PGoTLARecordSet.Field field) throws IOException {
		// TODO Auto-generated method stub
		return null;
	}

	@Override
	public Void visit(PGoTLARecordConstructor.Field field) throws IOException {
		// TODO Auto-generated method stub
		return null;
	}

	@Override
	public Void visit(PGoTLAQuantifierBound pGoTLAQuantifierBound) throws IOException {
		// TODO Auto-generated method stub
		return null;
	}

	@Override
	public Void visit(Remapping remapping) throws IOException {
		// TODO Auto-generated method stub
		return null;
	}

	@Override
	public Void visit(PGoTLAIdentifierOrTuple pGoTLAIdentifierOrTuple) throws IOException {
		if(pGoTLAIdentifierOrTuple.isTuple()) {
			out.write("<<");
			FormattingTools.writeCommaSeparated(out, pGoTLAIdentifierOrTuple.getTuple(), elem -> elem.accept(this));
			out.write(">>");
			
		}else {
			pGoTLAIdentifierOrTuple.getId().accept(this);
		}
		return null;
	}

	@Override
	public Void visit(PGoTLAIdentifier pGoTLAIdentifier) throws IOException {
		out.write(pGoTLAIdentifier.getId());
		return null;
	}

	@Override
	public Void visit(PGoTLAGeneralIdentifierPart pGoTLAGeneralIdentifierPart) throws IOException {
		pGoTLAGeneralIdentifierPart.getIdentifier().accept(this);
		List<PGoTLAExpression> params = pGoTLAGeneralIdentifierPart.getParameters();
		if(!params.isEmpty()) {
			out.write("(");
			FormattingTools.writeCommaSeparated(out, params, param -> {
				param.accept(new PGoTLAExpressionFormattingVisitor(out));
			});
			out.write(")");
		}
		out.write("!");
		return null;
	}

	@Override
	public Void visit(PGoTLAFunctionSubstitutionPair pGoTLAFunctionSubstitutionPair) throws IOException {
		out.write("!");
		for(PGoTLASubstitutionKey key : pGoTLAFunctionSubstitutionPair.getKeys()) {
			key.accept(this);
		}
		out.write("=");
		pGoTLAFunctionSubstitutionPair.getValue().accept(new PGoTLAExpressionFormattingVisitor(out));
		return null;
	}

}
