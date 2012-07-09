use QASTOperationsMAST;

my $MVM_reg_void            := 0; # not really a register; just a result/return kind marker
my $MVM_reg_int8            := 1;
my $MVM_reg_int16           := 2;
my $MVM_reg_int32           := 3;
my $MVM_reg_int64           := 4;
my $MVM_reg_num32           := 5;
my $MVM_reg_num64           := 6;
my $MVM_reg_str             := 7;
my $MVM_reg_obj             := 8;

class QAST::MASTCompiler {
    # This uses a very simple scheme. Write registers are assumed
    # to be write-once, read-once.  Therefore, if a QAST control
    # structure wants to reuse the intermediate result of an
    # expression, it must `set` the result to other registers before
    # using the result as an arg to another op.
    my class RegAlloc {
        has $!frame;
        has @!objs;
        has @!ints;
        has @!nums;
        has @!strs;
        
        method new($frame) {
            my $obj := nqp::create(self);
            nqp::bindattr($obj, RegAlloc, '$!frame', $frame);
            nqp::bindattr($obj, RegAlloc, '@!objs', []);
            nqp::bindattr($obj, RegAlloc, '@!ints', []);
            nqp::bindattr($obj, RegAlloc, '@!nums', []);
            nqp::bindattr($obj, RegAlloc, '@!strs', []);
            $obj
        }
        
        method fresh_i() { self.fresh_register($MVM_reg_int64) }
        method fresh_n() { self.fresh_register($MVM_reg_num64) }
        method fresh_s() { self.fresh_register($MVM_reg_str) }
        method fresh_o() { self.fresh_register($MVM_reg_obj) }
        
        # QAST::Vars need entirely new MAST::Locals all to themselves,
        # so a Local can't be a non-Var for the first half of a block and
        # then a Var the second half, but then control returns to the first half
        method fresh_register($kind, $new = 0) {
            my @arr; my $type;
            # set $new to 1 here if you suspect a problem with the allocator,
            # or if you suspect a register is being double-released somewhere.
            # $new := 1;
               if $kind == $MVM_reg_int64 { @arr := @!ints; $type := int }
            elsif $kind == $MVM_reg_num64 { @arr := @!nums; $type := num }
            elsif $kind == $MVM_reg_str   { @arr := @!strs; $type := str }
            elsif $kind == $MVM_reg_obj   { @arr := @!objs; $type := NQPMu }
            else { nqp::die("unhandled reg kind $kind") }
            
            nqp::elems(@arr) && !$new ?? nqp::pop(@arr) !!
                    MAST::Local.new($!frame.add_local($type))
        }
        
        method release_i($reg) { self.release_register($reg, $MVM_reg_int64) }
        method release_n($reg) { self.release_register($reg, $MVM_reg_int64) }
        method release_s($reg) { self.release_register($reg, $MVM_reg_int64) }
        method release_o($reg) { self.release_register($reg, $MVM_reg_int64) }
        
        method release_register($reg, $kind) {
            return 1 if $kind == $MVM_reg_void || $*BLOCK.is_var($reg);
            return nqp::push(@!ints, $reg) if $kind == $MVM_reg_int64;
            return nqp::push(@!nums, $reg) if $kind == $MVM_reg_num64;
            return nqp::push(@!strs, $reg) if $kind == $MVM_reg_str;
            return nqp::push(@!objs, $reg) if $kind == $MVM_reg_obj;
            nqp::die("unhandled reg kind $kind");
        }
    }
    
    # Holds information about the QAST::Block we're currently compiling.
    my class BlockInfo {
        has $!qast;                 # The QAST::Block
        has $!outer;                # Outer block's BlockInfo
        has %!local_names_by_index; # Locals' names by their indexes
        has %!locals;               # Mapping of local names to locals
        has %!local_kinds;          # Mapping of local registers to kinds
        has %!lexicals;             # Mapping of lexical names to registers
        has %!lexical_kinds;        # Mapping of lexical names to kinds
        has int $!param_idx;        # Current lexical parameter index
        has $!compiler;             # The QAST::MASTCompiler
        
        method new($qast, $outer, $compiler) {
            my $obj := nqp::create(self);
            $obj.BUILD($qast, $outer, $compiler);
            $obj
        }
        
        method BUILD($qast, $outer, $compiler) {
            $!qast := $qast;
            $!outer := $outer;
            $!compiler := $compiler;
        }
        
        method register_lexical($var) {
            my $name := $var.name;
            my $kind := $*REGALLOC.fresh_register($var.returns, 1);
            if nqp::existskey(%!lexical_kinds, $name) {
                nqp::die("Lexical '$name' already declared");
            }
            %!lexical_kinds{$name} := $kind;
            nqp::die("NYI");
            # %!lexicals{$name} := $*BLOCKRA."fresh_{nqp::lc($type)}"();
        }
        
        method register_local($var) {
            my $name := $var.name;
            if nqp::existskey(%!local_kinds, $name) {
                nqp::die("Local '$name' already declared");
            }
            my $kind := $!compiler.type_to_register_kind($var.returns // NQPMu);
            %!local_kinds{$name} := $kind;
            # pass a 1 meaning get a Totally New MAST::Local
            my $local := $*REGALLOC.fresh_register($kind, 1);
            %!locals{$name} := $local;
            %!local_names_by_index{$local.index} := $name;
            $local;
        }
        
        # returns whether a MAST::Local is a variable in this block
        method is_var($local) {
            nqp::existskey(%!local_names_by_index, $local.index)
        }
        
        method qast() { $!qast }
        method outer() { $!outer }
        method lexicals() { %!lexicals }
        method local($name) { %!locals{$name} }
        method local_kind($name) { %!local_kinds{$name} }
        method lexical_kind($name) { %!lexical_kinds{$name} }
    }
    
    our $serno := 0;
    method unique($prefix = '') { $prefix ~ $serno++ }
    
    method to_mast($qast) {
        my $*MAST_COMPUNIT := MAST::CompUnit.new();
        
        # map a QAST::Block's cuid to the MAST::Frame we
        # created for it, so we can find the Frame later
        # when we encounter the Block again in a call.
        my %*MAST_FRAMES := nqp::hash();
        
        self.as_mast($qast);
        $*MAST_COMPUNIT
    }
    
    proto method as_mast($qast) { * }
    
    multi method as_mast(QAST::Block $node) {
        # Create an empty frame and add it to the compilation unit.
        my $*MAST_FRAME := MAST::Frame.new(:name('xxx'), :cuuid('yyy'));
        $*MAST_COMPUNIT.add_frame($*MAST_FRAME);
        my $outer     := try $*BLOCK;
        my $block := BlockInfo.new($node, $outer, self);
        my $*BINDVAL := 0;
        my $cuid := $node.cuid();
        
        %*MAST_FRAMES{$cuid} := $*MAST_FRAME;
        
        # Create a register allocator for this frame.
        my $*REGALLOC := RegAlloc.new($*MAST_FRAME);

        # set the outer if it exists
        $*MAST_FRAME.set_outer($outer) if $outer && $outer ~~ MAST::Frame;

        # Compile all the substatements.
        my $ins;
        {
            my $*BLOCK := $block;
            $ins := self.compile_all_the_stmts(@($node));
        }

        # Add to instructions list for this block.
        # XXX Last thing is return value, later...
        nqp::splice($*MAST_FRAME.instructions, $ins.instructions, 0, 0);
        
        MAST::InstructionList.new(nqp::list(), MAST::VOID, $MVM_reg_void)
    }
    
    multi method as_mast(QAST::Stmts $node) {
        self.compile_all_the_stmts(@($node))
    }
    
    multi method as_mast(QAST::Stmt $node) {
        self.compile_all_the_stmts(@($node))
    }
    
    # This takes any node that is a statement list of some kind and compiles
    # all of the statements within it.
    method compile_all_the_stmts(@stmts) {
        my @all_ins;
        my $last_stmt;
        for @stmts {
            # Compile this child to MAST, and add its instructions to the end
            # of our instruction list. Also track the last statement.
            $last_stmt := self.as_mast($_);
            nqp::splice(@all_ins, $last_stmt.instructions, +@all_ins, 0);
        }
        MAST::InstructionList.new(@all_ins, $last_stmt.result_reg, $last_stmt.result_kind)
    }
    
    multi method as_mast(QAST::Op $node) {
        QAST::MASTOperations.compile_op(self, '', $node)
    }
    
    multi method as_mast(QAST::VM $vm) {
        if $vm.supports('moarop') {
            QAST::MASTOperations.compile_mastop(self, $vm.alternative('moarop'), $vm.list)
        }
        else {
            nqp::die("To compile on the MoarVM backend, QAST::VM must have an alternative 'moarop'");
        }
    }
    
    multi method as_mast(QAST::Var $node) {
        my $scope := $node.scope;
        my $decl  := $node.decl;
        
        # Handle any declarations; after this, we call through to the
        # lookup code.
        if $decl {
            # If it's a parameter, add it to the things we should bind
            # at block entry.
            if $decl eq 'param' {
                if $scope eq 'local' || $scope eq 'lexical' {
                    $*BLOCK.add_param($node);
                }
                else {
                    nqp::die("Parameter cannot have scope '$scope'; use 'local' or 'lexical'");
                }
            }
            elsif $decl eq 'var' {
                if $scope eq 'local' {
                    $*BLOCK.register_local($node);
                }
                elsif $scope eq 'lexical' {
                    $*BLOCK.add_lexical($node);
                }
                else {
                    nqp::die("Cannot declare variable with scope '$scope'; use 'local' or 'lexical'");
                }
            }
            else {
                nqp::die("Don't understand declaration type '$decl'");
            }
        }
        
        # Now go by scope.
        my $name := $node.name;
        my @ins;
        my $res_reg;
        my $res_kind;
        if $scope eq 'local' {
            if $*BLOCK.local_kind($name) -> $type {
                if $*BINDVAL {
                    my $valmast := self.as_mast_clear_bindval($*BINDVAL);
                    push_ilist(@ins, $valmast);
                    push_op(@ins, 'set', $*BLOCK.local($name), $valmast.result_reg);
                }
                $res_reg := $*BLOCK.local($name);
                $res_kind := $*BLOCK.local_kind($name);
            }
            else {
                nqp::die("Cannot reference undeclared local '$name'");
            }
        }
        elsif $scope eq 'lexical' {
            # If the lexical is directly declared in this block, we use the
            # register directly.
            if $*BLOCK.lexical_type($name) -> $type {
                my $reg := $*BLOCK.lex_reg($name);
                if $*BINDVAL {
                    my $valmast := self.as_mast_clear_bindval($*BINDVAL);
                    nqp::die("NYI 1");
                }
                $res_reg := $reg;
            }
            else {
                # Does the node have a native type marked on it?
                my $type := self.type_to_register_kind($node.returns);
                if $type eq 'P' {
                    # Consider the blocks for a declared native type.
                    # XXX TODO
                }
                
                # Emit the lookup or bind.
                if $*BINDVAL {
                    my $valpost := self.as_mast_clear_bindval($*BINDVAL);
                    nqp::die("NYI 2");
                }
                else {
                    my $res_reg := $*REGALLOC."fresh_{nqp::lc($type)}"();
                    $nqp::die("NYI 3");
                }
            }
        }
        elsif $scope eq 'attribute' {
            # Ensure we have object and class handle.
            my @args := $node.list();
            if +@args != 2 {
                nqp::die("An attribute lookup needs an object and a class handle");
            }
            
            # Compile object and handle.
            my $obj := self.coerce(self.as_post_clear_bindval(@args[0]), 'p');
            my $han := self.coerce(self.as_post_clear_bindval(@args[1]), 'p');
            nqp::die("NYI 4");
            
            # Go by whether it's a bind or lookup.
            my $type    := self.type_to_register_kind($node.returns);
            my $op_type := type_to_lookup_name($node.returns);
            if $*BINDVAL {
                my $valpost := self.as_mast_clear_bindval($*BINDVAL);
                nqp::die("NYI 5");
            }
            else {
                my $res_reg := $*REGALLOC."fresh_{nqp::lc($type)}"();
                nqp::die("NYI 6");
            }
        }
        else {
            nqp::die("QAST::Var with scope '$scope' NYI");
        }
        
        MAST::InstructionList.new(@ins, $res_reg, $res_kind)
    }
    
    method as_mast_clear_bindval($node) {
        my $*BINDVAL := 0;
        self.as_mast($node)
    }
    
    multi method as_mast(QAST::IVal $iv) {
        my $reg := $*REGALLOC.fresh_i();
        MAST::InstructionList.new(
            [MAST::Op.new(
                :bank('primitives'), :op('const_i64'),
                $reg,
                MAST::IVal.new( :value($iv.value) )
            )],
            $reg,
            $MVM_reg_int64)
    }
    
    multi method as_mast(QAST::NVal $nv) {
        my $reg := $*REGALLOC.fresh_n();
        MAST::InstructionList.new(
            [MAST::Op.new(
                :bank('primitives'), :op('const_n64'),
                $reg,
                MAST::NVal.new( :value($nv.value) )
            )],
            $reg,
            $MVM_reg_num64)
    }
    
    multi method as_mast(QAST::SVal $sv) {
        my $reg := $*REGALLOC.fresh_s();
        MAST::InstructionList.new(
            [MAST::Op.new(
                :bank('primitives'), :op('const_s'),
                $reg,
                MAST::SVal.new( :value($sv.value) )
            )],
            $reg,
            $MVM_reg_str)
    }

    multi method as_mast(QAST::BVal $bv) {
        
        my $block := $bv.value;
        my $cuid  := $block.cuid();
        my $frame := %*MAST_FRAMES{$cuid};
        nqp::die("QAST::Block with cuid $cuid has not appeared")
            unless $frame && $frame ~~ MAST::Frame;
        
        my $reg := $*REGALLOC.fresh_o();
        MAST::InstructionList.new(
            [MAST::Op.new(
                :bank('primitives'), :op('getcode'),
                $reg,
                $frame
            )],
            $reg,
            $MVM_reg_obj)
    }

    multi method as_mast(QAST::Regex $node) {
        # Prefix for the regexes code pieces.
        my $prefix := self.unique('rx') ~ '_';

        # Build the list of (unique) registers we need
        my %*REG := nqp::hash(
            'tgt', $*REGALLOC.fresh_s(),
            'pos', $*REGALLOC.fresh_i(),
            'off', $*REGALLOC.fresh_i(),
            'eos', $*REGALLOC.fresh_i(),
            'rep', $*REGALLOC.fresh_i(),
            'cur', $*REGALLOC.fresh_o(),
            'curclass', $*REGALLOC.fresh_o(),
            'bstack', $*REGALLOC.fresh_o(),
            'cstack', $*REGALLOC.fresh_o());

        # create our labels
        my $startlabel   := MAST::Label.new( :name($prefix ~ 'start') );
        my $donelabel    := MAST::Label.new( :name($prefix ~ 'done') );
        my $restartlabel := MAST::Label.new( :name($prefix ~ 'restart') );
        my $faillabel    := MAST::Label.new( :name($prefix ~ 'fail') );
        my $jumplabel    := MAST::Label.new( :name($prefix ~ 'jump') );
        my $cutlabel     := MAST::Label.new( :name($prefix ~ 'cut') );
        my $cstacklabel  := MAST::Label.new( :name($prefix ~ 'cstack_done') );
        %*REG<fail>      := $faillabel;

        nqp::die("Regex compilation NYI");
    }
    
    my @prim_to_reg := [$MVM_reg_obj, $MVM_reg_int64, $MVM_reg_num64, $MVM_reg_str];
    method type_to_register_kind($type) {
        @prim_to_reg[pir::repr_get_primitive_type_spec__IP($type)]
    }
}

sub push_op(@dest, $op, *@args) {
    # Resolve the op.
    my $bank;
    for MAST::Ops.WHO {
        $bank := ~$_ if nqp::existskey(MAST::Ops.WHO{~$_}, $op);
    }
    nqp::die("Unable to resolve MAST op '$op'") unless nqp::defined($bank);
    
    nqp::push(@dest, MAST::Op.new(
        :bank(nqp::substr($bank, 1)), :op($op),
        |@args
    ));
}
