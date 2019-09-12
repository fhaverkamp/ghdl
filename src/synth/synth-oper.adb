--  Operations synthesis.
--  Copyright (C) 2019 Tristan Gingold
--
--  This file is part of GHDL.
--
--  This program is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program; if not, write to the Free Software
--  Foundation, Inc., 51 Franklin Street - Fifth Floor, Boston,
--  MA 02110-1301, USA.

with Ada.Unchecked_Conversion;
with Types; use Types;
with Types_Utils; use Types_Utils;
with Mutils; use Mutils;
with Vhdl.Ieee.Std_Logic_1164; use Vhdl.Ieee.Std_Logic_1164;
with Vhdl.Std_Package;
with Vhdl.Errors; use Vhdl.Errors;
with Vhdl.Utils; use Vhdl.Utils;

with Areapools;
with Vhdl.Annotations; use Vhdl.Annotations;

with Netlists; use Netlists;
with Netlists.Gates; use Netlists.Gates;
with Netlists.Builders; use Netlists.Builders;

with Synth.Errors; use Synth.Errors;
with Synth.Types; use Synth.Types;
with Synth.Stmts; use Synth.Stmts;
with Synth.Expr; use Synth.Expr;

package body Synth.Oper is
   --  As log2(3m) is directly referenced, the program must be linked with -lm
   --  (math library) on unix systems.
   pragma Linker_Options ("-lm");

   function Synth_Uresize (N : Net; W : Width; Loc : Node) return Net
   is
      Wn : constant Width := Get_Width (N);
      Res : Net;
   begin
      if Wn = W then
         return N;
      else
         if Wn > W then
            Res := Build_Trunc (Build_Context, Id_Utrunc, N, W);
         else
            pragma Assert (Wn < W);
            Res := Build_Extend (Build_Context, Id_Uextend, N, W);
         end if;
         Set_Location (Res, Loc);
         return Res;
      end if;
   end Synth_Uresize;

   function Synth_Sresize (N : Net; W : Width; Loc : Node) return Net
   is
      Wn : constant Width := Get_Width (N);
      Res : Net;
   begin
      if Wn = W then
         return N;
      else
         if Wn > W then
            Res := Build_Trunc (Build_Context, Id_Strunc, N, W);
         else
            pragma Assert (Wn < W);
            Res := Build_Extend (Build_Context, Id_Sextend, N, W);
         end if;
         Set_Location (Res, Loc);
         return Res;
      end if;
   end Synth_Sresize;

   function Synth_Uresize (Val : Value_Acc; W : Width; Loc : Node) return Net
   is
      Res : Net;
   begin
      if Is_Const (Val) and then Val.Typ.Kind = Type_Discrete then
         if Val.Typ.Drange.Is_Signed then
            --  TODO.
            raise Internal_Error;
         else
            Res := Build2_Const_Uns (Build_Context, To_Uns64 (Val.Scal), W);
         end if;
         Set_Location (Res, Loc);
         return Res;
      end if;
      return Synth_Uresize (Get_Net (Val), W, Loc);
   end Synth_Uresize;

   function Synth_Bit_Eq_Const (Cst : Value_Acc; Expr : Value_Acc; Loc : Node)
                               return Value_Acc
   is
      Val : Uns32;
      Zx : Uns32;
      N : Net;
   begin
      if Is_Const (Expr) then
         return Create_Value_Discrete (Boolean'Pos (Cst.Scal = Expr.Scal),
                                       Boolean_Type);
      end if;

      To_Logic (Cst.Scal, Cst.Typ, Val, Zx);
      if Zx /= 0 then
         --  Equal unknown -> return X
         N := Build_Const_UL32 (Build_Context, 0, 1, 1);
         Set_Location (N, Loc);
         return Create_Value_Net (N, Boolean_Type);
      elsif Val = 1 then
         return Expr;
      else
         pragma Assert (Val = 0);
         N := Build_Monadic (Build_Context, Id_Not, Get_Net (Expr));
         Set_Location (N, Loc);
         return Create_Value_Net (N, Boolean_Type);
      end if;
   end Synth_Bit_Eq_Const;

   --  Create the result range of an operator.  According to the ieee standard,
   --  the range is LEN-1 downto 0.
   function Create_Res_Bound (Prev : Value_Acc; N : Net) return Type_Acc
   is
      Res : Type_Acc;
      Wd : Width;
   begin
      Res := Prev.Typ;

      if Res.Vbound.Dir = Iir_Downto
        and then Res.Vbound.Right = 0
      then
         --  Normalized range
         return Res;
      end if;

      Wd := Get_Width (N);
      return Create_Vec_Type_By_Length (Wd, Res.Vec_El);
   end Create_Res_Bound;

   function Create_Bounds_From_Length
     (Syn_Inst : Synth_Instance_Acc; Atype : Iir; Len : Iir_Index32)
     return Bound_Type
   is
      Res : Bound_Type;
      Index_Bounds : Discrete_Range_Type;
      W : Width;
   begin
      Synth_Discrete_Range (Syn_Inst, Atype, Index_Bounds, W);

      Res := (Left => Int32 (Index_Bounds.Left),
              Right => 0,
              Dir => Index_Bounds.Dir,
              Wbounds => W,
              Wlen => Width (Clog2 (Uns64 (Len))),
              Len => Uns32 (Len));

      if Len = 0 then
         --  Special case.
         Res.Right := Res.Left;
         case Index_Bounds.Dir is
            when Iir_To =>
               Res.Left := Res.Right + 1;
            when Iir_Downto =>
               Res.Left := Res.Right - 1;
         end case;
      else
         case Index_Bounds.Dir is
            when Iir_To =>
               Res.Right := Res.Left + Int32 (Len - 1);
            when Iir_Downto =>
               Res.Right := Res.Left - Int32 (Len - 1);
         end case;
      end if;
      return Res;
   end Create_Bounds_From_Length;

   function Synth_Dyadic_Operation (Syn_Inst : Synth_Instance_Acc;
                                    Imp : Node;
                                    Left_Expr : Node;
                                    Right_Expr : Node;
                                    Expr : Node) return Value_Acc
   is
      Def : constant Iir_Predefined_Functions :=
        Get_Implicit_Definition (Imp);
      Inter_Chain : constant Node :=
        Get_Interface_Declaration_Chain (Imp);
      Expr_Type : constant Node := Get_Type (Expr);
      Left_Type : constant Node := Get_Type (Inter_Chain);
      Right_Type : constant Node := Get_Type (Get_Chain (Inter_Chain));
      Left : Value_Acc;
      Right : Value_Acc;

      function Synth_Bit_Dyadic (Id : Dyadic_Module_Id) return Value_Acc
      is
         N : Net;
      begin
         N := Build_Dyadic (Build_Context, Id,
                            Get_Net (Left), Get_Net (Right));
         Set_Location (N, Expr);
         return Create_Value_Net (N, Left.Typ);
      end Synth_Bit_Dyadic;

      function Synth_Compare (Id : Compare_Module_Id) return Value_Acc
      is
         N : Net;
         L, R : Value_Acc;
         Typ : Type_Acc;
      begin
         pragma Assert (Left_Type = Right_Type);
         Typ := Get_Value_Type (Syn_Inst, Left_Type);
         L := Synth_Subtype_Conversion (Left, Typ, Expr);
         R := Synth_Subtype_Conversion (Right, Typ, Expr);
         N := Build_Compare (Build_Context, Id, Get_Net (L), Get_Net (R));
         Set_Location (N, Expr);
         return Create_Value_Net (N, Boolean_Type);
      end Synth_Compare;

      function Synth_Compare_Uns_Nat (Id : Compare_Module_Id)
                                     return Value_Acc
      is
         N : Net;
      begin
         N := Synth_Uresize (Right, Left.Typ.W, Expr);
         N := Build_Compare (Build_Context, Id, Get_Net (Left), N);
         Set_Location (N, Expr);
         return Create_Value_Net (N, Boolean_Type);
      end Synth_Compare_Uns_Nat;

      function Synth_Vec_Dyadic (Id : Dyadic_Module_Id) return Value_Acc
      is
         L : constant Net := Get_Net (Left);
         N : Net;
      begin
         N := Build_Dyadic (Build_Context, Id, L, Get_Net (Right));
         Set_Location (N, Expr);
         return Create_Value_Net (N, Create_Res_Bound (Left, L));
      end Synth_Vec_Dyadic;

      function Synth_Int_Dyadic (Id : Dyadic_Module_Id) return Value_Acc
      is
         Etype : constant Type_Acc := Get_Value_Type (Syn_Inst, Expr_Type);
         N : Net;
      begin
         N := Build_Dyadic
           (Build_Context, Id, Get_Net (Left), Get_Net (Right));
         Set_Location (N, Expr);
         return Create_Value_Net (N, Etype);
      end Synth_Int_Dyadic;

      function Synth_Dyadic_Uns (Id : Dyadic_Module_Id; Is_Res_Vec : Boolean)
                                return Value_Acc
      is
         L : constant Net := Get_Net (Left);
         R : constant Net := Get_Net (Right);
         W : constant Width := Width'Max (Get_Width (L), Get_Width (R));
         Rtype : Type_Acc;
         L1, R1 : Net;
         N : Net;
      begin
         if Is_Res_Vec then
            Rtype := Create_Vec_Type_By_Length (W, Left.Typ.Vec_El);
         else
            Rtype := Left.Typ;
         end if;
         L1 := Synth_Uresize (L, W, Expr);
         R1 := Synth_Uresize (R, W, Expr);
         N := Build_Dyadic (Build_Context, Id, L1, R1);
         Set_Location (N, Expr);
         return Create_Value_Net (N, Rtype);
      end Synth_Dyadic_Uns;

      function Synth_Dyadic_Sgn (Id : Dyadic_Module_Id; Is_Res_Vec : Boolean)
                                return Value_Acc
      is
         L : constant Net := Get_Net (Left);
         R : constant Net := Get_Net (Right);
         W : constant Width := Width'Max (Get_Width (L), Get_Width (R));
         Rtype : Type_Acc;
         L1, R1 : Net;
         N : Net;
      begin
         if Is_Res_Vec then
            Rtype := Create_Vec_Type_By_Length (W, Left.Typ.Vec_El);
         else
            Rtype := Left.Typ;
         end if;
         L1 := Synth_Sresize (L, W, Expr);
         R1 := Synth_Sresize (R, W, Expr);
         N := Build_Dyadic (Build_Context, Id, L1, R1);
         Set_Location (N, Expr);
         return Create_Value_Net (N, Rtype);
      end Synth_Dyadic_Sgn;

      function Synth_Compare_Uns_Uns (Id : Compare_Module_Id)
                                     return Value_Acc
      is
         L : constant Net := Get_Net (Left);
         R : constant Net := Get_Net (Right);
         W : constant Width := Width'Max (Get_Width (L), Get_Width (R));
         L1, R1 : Net;
         N : Net;
      begin
         L1 := Synth_Uresize (L, W, Expr);
         R1 := Synth_Uresize (R, W, Expr);
         N := Build_Compare (Build_Context, Id, L1, R1);
         Set_Location (N, Expr);
         return Create_Value_Net (N, Boolean_Type);
      end Synth_Compare_Uns_Uns;

      function Synth_Dyadic_Uns_Nat (Id : Dyadic_Module_Id) return Value_Acc
      is
         L : constant Net := Get_Net (Left);
         R1 : Net;
         N : Net;
      begin
         R1 := Synth_Uresize (Right, Left.Typ.W, Expr);
         N := Build_Dyadic (Build_Context, Id, L, R1);
         Set_Location (N, Expr);
         return Create_Value_Net (N, Create_Res_Bound (Left, L));
      end Synth_Dyadic_Uns_Nat;

      function Synth_Compare_Sgn_Sgn (Id : Compare_Module_Id)
                                     return Value_Acc
      is
         L : constant Net := Get_Net (Left);
         R : constant Net := Get_Net (Right);
         W : constant Width := Width'Max (Get_Width (L), Get_Width (R));
         L1, R1 : Net;
         N : Net;
      begin
         L1 := Synth_Sresize (L, W, Expr);
         R1 := Synth_Sresize (R, W, Expr);
         N := Build_Compare (Build_Context, Id, L1, R1);
         Set_Location (N, Expr);
         return Create_Value_Net (N, Boolean_Type);
      end Synth_Compare_Sgn_Sgn;

   begin
      Left := Synth_Expression_With_Type (Syn_Inst, Left_Expr, Left_Type);
      Right := Synth_Expression_With_Type (Syn_Inst, Right_Expr, Right_Type);

      case Def is
         when Iir_Predefined_Error =>
            return null;

         when Iir_Predefined_Bit_And
           | Iir_Predefined_Boolean_And
           | Iir_Predefined_Ieee_1164_Scalar_And =>
            return Synth_Bit_Dyadic (Id_And);
         when Iir_Predefined_Bit_Xor
           | Iir_Predefined_Ieee_1164_Scalar_Xor =>
            return Synth_Bit_Dyadic (Id_Xor);
         when Iir_Predefined_Bit_Or
           | Iir_Predefined_Boolean_Or
           | Iir_Predefined_Ieee_1164_Scalar_Or =>
            return Synth_Bit_Dyadic (Id_Or);
         when Iir_Predefined_Bit_Nor
           | Iir_Predefined_Ieee_1164_Scalar_Nor =>
            return Synth_Bit_Dyadic (Id_Nor);
         when Iir_Predefined_Bit_Nand
           | Iir_Predefined_Ieee_1164_Scalar_Nand =>
            return Synth_Bit_Dyadic (Id_Nand);
         when Iir_Predefined_Bit_Xnor
           | Iir_Predefined_Ieee_1164_Scalar_Xnor =>
            return Synth_Bit_Dyadic (Id_Xnor);

         when Iir_Predefined_Ieee_1164_Vector_And
            | Iir_Predefined_Ieee_Numeric_Std_And_Uns_Uns
            | Iir_Predefined_Ieee_Numeric_Std_And_Sgn_Sgn =>
            return Synth_Vec_Dyadic (Id_And);
         when Iir_Predefined_Ieee_1164_Vector_Or
            | Iir_Predefined_Ieee_Numeric_Std_Or_Uns_Uns
            | Iir_Predefined_Ieee_Numeric_Std_Or_Sgn_Sgn =>
            return Synth_Vec_Dyadic (Id_Or);
         when Iir_Predefined_Ieee_1164_Vector_Nand
            | Iir_Predefined_Ieee_Numeric_Std_Nand_Uns_Uns
            | Iir_Predefined_Ieee_Numeric_Std_Nand_Sgn_Sgn =>
            return Synth_Vec_Dyadic (Id_Nand);
         when Iir_Predefined_Ieee_1164_Vector_Nor
            | Iir_Predefined_Ieee_Numeric_Std_Nor_Uns_Uns
            | Iir_Predefined_Ieee_Numeric_Std_Nor_Sgn_Sgn =>
            return Synth_Vec_Dyadic (Id_Nor);
         when Iir_Predefined_Ieee_1164_Vector_Xor
            | Iir_Predefined_Ieee_Numeric_Std_Xor_Uns_Uns
            | Iir_Predefined_Ieee_Numeric_Std_Xor_Sgn_Sgn =>
            return Synth_Vec_Dyadic (Id_Xor);
         when Iir_Predefined_Ieee_1164_Vector_Xnor
            | Iir_Predefined_Ieee_Numeric_Std_Xnor_Uns_Uns
            | Iir_Predefined_Ieee_Numeric_Std_Xnor_Sgn_Sgn =>
            return Synth_Vec_Dyadic (Id_Xnor);

         when Iir_Predefined_Enum_Equality =>
            if Is_Bit_Type (Left_Type) then
               pragma Assert (Is_Bit_Type (Right_Type));
               if Is_Const (Left) then
                  return Synth_Bit_Eq_Const (Left, Right, Expr);
               elsif Is_Const (Right) then
                  return Synth_Bit_Eq_Const (Right, Left, Expr);
               end if;
            end if;
            return Synth_Compare (Id_Eq);
         when Iir_Predefined_Enum_Inequality =>
            --  TODO: Optimize ?
            return Synth_Compare (Id_Ne);
         when Iir_Predefined_Enum_Less_Equal =>
            return Synth_Compare (Id_Ult);

         when Iir_Predefined_Array_Equality =>
            --  TODO: check size, handle non-vector.
            if Is_Vector_Type (Left_Type) then
               return Synth_Compare (Id_Eq);
            else
               raise Internal_Error;
            end if;
         when Iir_Predefined_Array_Inequality =>
            --  TODO: check size, handle non-vector.
            if Is_Vector_Type (Left_Type) then
               return Synth_Compare (Id_Ne);
            else
               raise Internal_Error;
            end if;
         when Iir_Predefined_Array_Greater =>
            --  TODO: check size, non-vector.
            --  TODO: that's certainly not the correct operator.
            if Is_Vector_Type (Left_Type) then
               return Synth_Compare (Id_Ugt);
            else
               raise Internal_Error;
            end if;

         when Iir_Predefined_Ieee_Numeric_Std_Add_Uns_Nat =>
            --  "+" (Unsigned, Natural)
            return Synth_Dyadic_Uns_Nat (Id_Add);
         when Iir_Predefined_Ieee_Numeric_Std_Add_Uns_Uns
           | Iir_Predefined_Ieee_Numeric_Std_Add_Uns_Log
           | Iir_Predefined_Ieee_Std_Logic_Unsigned_Add_Slv_Sl =>
            --  "+" (Unsigned, Unsigned)
            return Synth_Dyadic_Uns (Id_Add, True);
         when Iir_Predefined_Ieee_Numeric_Std_Add_Sgn_Sgn =>
            --  "+" (Signed, Signed)
            return Synth_Dyadic_Sgn (Id_Add, True);
         when Iir_Predefined_Ieee_Numeric_Std_Sub_Uns_Nat =>
            --  "-" (Unsigned, Natural)
            return Synth_Dyadic_Uns_Nat (Id_Sub);
         when Iir_Predefined_Ieee_Numeric_Std_Sub_Uns_Uns =>
            --  "-" (Unsigned, Unsigned)
            return Synth_Dyadic_Uns (Id_Sub, True);

         when Iir_Predefined_Ieee_Numeric_Std_Mul_Sgn_Sgn =>
            declare
               L : constant Net := Get_Net (Left);
               R : constant Net := Get_Net (Right);
               W : constant Width := Get_Width (L) + Get_Width (R);
               Rtype : Type_Acc;
               N : Net;
            begin
               Rtype := Create_Vec_Type_By_Length (W, Left.Typ.Vec_El);
               N := Build_Dyadic (Build_Context, Id_Smul, L, R);
               Set_Location (N, Expr);
               return Create_Value_Net (N, Rtype);
            end;

         when Iir_Predefined_Ieee_Numeric_Std_Eq_Uns_Nat =>
            --  "=" (Unsigned, Natural)
            return Synth_Compare_Uns_Nat (Id_Eq);
         when Iir_Predefined_Ieee_Numeric_Std_Eq_Uns_Uns
           | Iir_Predefined_Ieee_Std_Logic_Unsigned_Eq_Slv_Slv =>
            --  "=" (Unsigned, Unsigned) [resize]
            return Synth_Compare_Uns_Uns (Id_Eq);

         when Iir_Predefined_Ieee_Numeric_Std_Ne_Uns_Uns
           | Iir_Predefined_Ieee_Std_Logic_Unsigned_Ne_Slv_Slv =>
            --  "/=" (Unsigned, Unsigned) [resize]
            return Synth_Compare_Uns_Uns (Id_Ne);
         when Iir_Predefined_Ieee_Numeric_Std_Ne_Uns_Nat =>
            --  "/=" (Unsigned, Natural)
            return Synth_Compare_Uns_Nat (Id_Ne);

         when Iir_Predefined_Ieee_Numeric_Std_Lt_Uns_Nat =>
            --  "<" (Unsigned, Natural)
            if Is_Const (Right) and then Right.Scal = 0 then
               --  Always false.
               return Create_Value_Discrete (0, Boolean_Type);
            end if;
            return Synth_Compare_Uns_Nat (Id_Ult);
         when Iir_Predefined_Ieee_Numeric_Std_Lt_Uns_Uns
           | Iir_Predefined_Ieee_Std_Logic_Unsigned_Lt_Slv_Slv =>
            --  "<" (Unsigned, Unsigned) [resize]
            return Synth_Compare_Uns_Uns (Id_Ult);
         when Iir_Predefined_Ieee_Numeric_Std_Lt_Sgn_Sgn =>
            --  "<" (Signed, Signed) [resize]
            return Synth_Compare_Sgn_Sgn (Id_Slt);

         when Iir_Predefined_Ieee_Numeric_Std_Le_Uns_Uns
           | Iir_Predefined_Ieee_Std_Logic_Unsigned_Le_Slv_Slv =>
            --  "<=" (Unsigned, Unsigned) [resize]
            return Synth_Compare_Uns_Uns (Id_Ule);

         when Iir_Predefined_Ieee_Numeric_Std_Gt_Uns_Nat =>
            --  ">" (Unsigned, Natural)
            return Synth_Compare_Uns_Nat (Id_Ugt);
         when Iir_Predefined_Ieee_Numeric_Std_Gt_Uns_Uns
           | Iir_Predefined_Ieee_Std_Logic_Unsigned_Gt_Slv_Slv =>
            --  ">" (Unsigned, Unsigned) [resize]
            return Synth_Compare_Uns_Uns (Id_Ugt);
         when Iir_Predefined_Ieee_Numeric_Std_Gt_Sgn_Sgn =>
            --  ">" (Signed, Signed) [resize]
            return Synth_Compare_Sgn_Sgn (Id_Sgt);

         when Iir_Predefined_Ieee_Numeric_Std_Ge_Uns_Uns
           | Iir_Predefined_Ieee_Std_Logic_Unsigned_Ge_Slv_Slv =>
            --  ">=" (Unsigned, Unsigned) [resize]
            return Synth_Compare_Uns_Uns (Id_Uge);

         when Iir_Predefined_Array_Element_Concat =>
            declare
               L : constant Net := Get_Net (Left);
               Bnd : Bound_Type;
               N : Net;
            begin
               N := Build_Concat2 (Build_Context, L, Get_Net (Right));
               Set_Location (N, Expr);
               Bnd := Create_Bounds_From_Length
                 (Syn_Inst,
                  Get_Index_Type (Get_Type (Expr), 0),
                  Iir_Index32 (Get_Width (L) + 1));

               return Create_Value_Net
                 (N, Create_Vector_Type (Bnd, Right.Typ));
            end;
         when Iir_Predefined_Element_Array_Concat =>
            declare
               R : constant Net := Get_Net (Right);
               Bnd : Bound_Type;
               N : Net;
            begin
               N := Build_Concat2 (Build_Context, Get_Net (Left), R);
               Set_Location (N, Expr);
               Bnd := Create_Bounds_From_Length
                 (Syn_Inst,
                  Get_Index_Type (Get_Type (Expr), 0),
                  Iir_Index32 (Get_Width (R) + 1));

               return Create_Value_Net
                 (N, Create_Vector_Type (Bnd, Left.Typ));
            end;
         when Iir_Predefined_Element_Element_Concat =>
            declare
               N : Net;
               Bnd : Bound_Type;
            begin
               N := Build_Concat2
                 (Build_Context, Get_Net (Left), Get_Net (Right));
               Set_Location (N, Expr);
               Bnd := Create_Bounds_From_Length
                 (Syn_Inst, Get_Index_Type (Get_Type (Expr), 0), 2);
               return Create_Value_Net
                 (N, Create_Vector_Type (Bnd, Left.Typ));
            end;
         when Iir_Predefined_Array_Array_Concat =>
            declare
               L : constant Net := Get_Net (Left);
               R : constant Net := Get_Net (Right);
               Bnd : Bound_Type;
               N : Net;
            begin
               N := Build_Concat2 (Build_Context, L, R);
               Set_Location (N, Expr);
               Bnd := Create_Bounds_From_Length
                 (Syn_Inst,
                  Get_Index_Type (Get_Type (Expr), 0),
                  Iir_Index32 (Get_Width (L) + Get_Width (R)));

               return Create_Value_Net
                 (N, Create_Vector_Type (Bnd, Left.Typ.Vec_El));
            end;
         when Iir_Predefined_Integer_Plus =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Left.Scal + Right.Scal,
                  Get_Value_Type (Syn_Inst, Get_Type (Expr)));
            else
               return Synth_Int_Dyadic (Id_Add);
            end if;
         when Iir_Predefined_Integer_Minus =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Left.Scal - Right.Scal,
                  Get_Value_Type (Syn_Inst, Get_Type (Expr)));
            else
               return Synth_Int_Dyadic (Id_Sub);
            end if;
         when Iir_Predefined_Integer_Mul =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Left.Scal * Right.Scal,
                  Get_Value_Type (Syn_Inst, Get_Type (Expr)));
            else
               return Synth_Int_Dyadic (Id_Smul);
            end if;
         when Iir_Predefined_Integer_Div =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Left.Scal / Right.Scal,
                  Get_Value_Type (Syn_Inst, Get_Type (Expr)));
            else
               Error_Msg_Synth (+Expr, "non-constant division not supported");
               return null;
            end if;
         when Iir_Predefined_Integer_Mod =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Left.Scal mod Right.Scal,
                  Get_Value_Type (Syn_Inst, Get_Type (Expr)));
            else
               Error_Msg_Synth (+Expr, "non-constant mod not supported");
               return null;
            end if;
         when Iir_Predefined_Integer_Rem =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Left.Scal rem Right.Scal,
                  Get_Value_Type (Syn_Inst, Get_Type (Expr)));
            else
               Error_Msg_Synth (+Expr, "non-constant rem not supported");
               return null;
            end if;
         when Iir_Predefined_Integer_Exp =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Left.Scal ** Natural (Right.Scal),
                  Get_Value_Type (Syn_Inst, Get_Type (Expr)));
            else
               Error_Msg_Synth
                 (+Expr, "non-constant exponentiation not supported");
               return null;
            end if;
         when Iir_Predefined_Integer_Less_Equal =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Boolean'Pos (Left.Scal <= Right.Scal), Boolean_Type);
            else
               return Synth_Compare (Id_Sle);
            end if;
         when Iir_Predefined_Integer_Less =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Boolean'Pos (Left.Scal < Right.Scal), Boolean_Type);
            else
               return Synth_Compare (Id_Slt);
            end if;
         when Iir_Predefined_Integer_Greater_Equal =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Boolean'Pos (Left.Scal >= Right.Scal), Boolean_Type);
            else
               return Synth_Compare (Id_Sge);
            end if;
         when Iir_Predefined_Integer_Greater =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Boolean'Pos (Left.Scal > Right.Scal), Boolean_Type);
            else
               return Synth_Compare (Id_Sgt);
            end if;
         when Iir_Predefined_Integer_Equality =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Boolean'Pos (Left.Scal = Right.Scal), Boolean_Type);
            else
               return Synth_Compare (Id_Eq);
            end if;
         when Iir_Predefined_Integer_Inequality =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Boolean'Pos (Left.Scal /= Right.Scal), Boolean_Type);
            else
               return Synth_Compare (Id_Ne);
            end if;
         when Iir_Predefined_Physical_Physical_Div =>
            if Is_Const (Left) and then Is_Const (Right) then
               return Create_Value_Discrete
                 (Left.Scal / Right.Scal,
                  Get_Value_Type (Syn_Inst, Get_Type (Expr)));
            else
               Error_Msg_Synth (+Expr, "non-constant division not supported");
               return null;
            end if;

         when others =>
            Error_Msg_Synth (+Expr, "synth_dyadic_operation: unhandled "
                               & Iir_Predefined_Functions'Image (Def));
            raise Internal_Error;
      end case;
   end Synth_Dyadic_Operation;

   function Synth_Monadic_Operation (Syn_Inst : Synth_Instance_Acc;
                                     Def : Iir_Predefined_Functions;
                                     Operand_Expr : Node;
                                     Loc : Node) return Value_Acc
   is
      Operand : Value_Acc;

      function Synth_Bit_Monadic (Id : Monadic_Module_Id) return Value_Acc
      is
         N : Net;
      begin
         N := Build_Monadic (Build_Context, Id, Get_Net (Operand));
         Set_Location (N, Loc);
         return Create_Value_Net (N, Operand.Typ);
      end Synth_Bit_Monadic;

      function Synth_Vec_Monadic (Id : Monadic_Module_Id) return Value_Acc
      is
         Op: constant Net := Get_Net (Operand);
         N : Net;
      begin
         N := Build_Monadic (Build_Context, Id, Op);
         Set_Location (N, Loc);
         return Create_Value_Net (N, Create_Res_Bound (Operand, Op));
      end Synth_Vec_Monadic;

      function Synth_Vec_Reduce_Monadic (Id : Reduce_Module_Id)
         return Value_Acc
      is
         Op: constant Net := Get_Net (Operand);
         N : Net;
      begin
         N := Build_Reduce (Build_Context, Id, Op);
         Set_Location (N, Loc);
         return Create_Value_Net (N, Operand.Typ.Vec_El);
      end Synth_Vec_Reduce_Monadic;
   begin
      Operand := Synth_Expression (Syn_Inst, Operand_Expr);
      case Def is
         when Iir_Predefined_Error =>
            return null;
         when Iir_Predefined_Ieee_1164_Scalar_Not =>
            return Synth_Bit_Monadic (Id_Not);
         when Iir_Predefined_Ieee_1164_Vector_Not
            | Iir_Predefined_Ieee_Numeric_Std_Not_Uns
            | Iir_Predefined_Ieee_Numeric_Std_Not_Sgn =>
            return Synth_Vec_Monadic (Id_Not);
         when Iir_Predefined_Ieee_Numeric_Std_Neg_Uns
           | Iir_Predefined_Ieee_Numeric_Std_Neg_Sgn =>
            return Synth_Vec_Monadic (Id_Neg);
         when Iir_Predefined_Ieee_1164_Vector_And_Reduce =>
            return Synth_Vec_Reduce_Monadic(Id_Red_And);
         when Iir_Predefined_Ieee_1164_Vector_Or_Reduce =>
            return Synth_Vec_Reduce_Monadic(Id_Red_Or);
         when Iir_Predefined_Ieee_1164_Condition_Operator =>
            return Operand;
         when others =>
            Error_Msg_Synth
              (+Loc,
               "unhandled monadic: " & Iir_Predefined_Functions'Image (Def));
            raise Internal_Error;
      end case;
   end Synth_Monadic_Operation;

   function Synth_Shift (Id : Shift_Module_Id;
                         Left, Right : Value_Acc;
                         Expr : Node) return Value_Acc
   is
      L : constant Net := Get_Net (Left);
      N : Net;
   begin
      N := Build_Shift (Build_Context, Id, L, Get_Net (Right));
      Set_Location (N, Expr);
      return Create_Value_Net (N, Create_Res_Bound (Left, L));
   end Synth_Shift;

   function Eval_To_Unsigned (Arg : Int64; Sz : Int64; Res_Type : Type_Acc)
                             return Value_Acc
   is
      Len : constant Iir_Index32 := Iir_Index32 (Sz);
      El_Type : constant Type_Acc := Get_Array_Element (Res_Type);
      Arr : Value_Array_Acc;
      Bnd : Type_Acc;
   begin
      Arr := Create_Value_Array (Len);
      for I in 1 .. Len loop
         Arr.V (Len - I + 1) := Create_Value_Discrete
           (Std_Logic_0_Pos + (Arg / 2 ** Natural (I - 1)) mod 2, El_Type);
      end loop;
      Bnd := Create_Vec_Type_By_Length (Width (Len), El_Type);
      return Create_Value_Const_Array (Bnd, Arr);
   end Eval_To_Unsigned;

   function Synth_Predefined_Function_Call
     (Syn_Inst : Synth_Instance_Acc; Expr : Node) return Value_Acc
   is
      Imp  : constant Node := Get_Implementation (Expr);
      Def : constant Iir_Predefined_Functions :=
        Get_Implicit_Definition (Imp);
      Assoc_Chain : constant Node := Get_Parameter_Association_Chain (Expr);
      Inter_Chain : constant Node := Get_Interface_Declaration_Chain (Imp);
      Subprg_Inst : Synth_Instance_Acc;
      M : Areapools.Mark_Type;
   begin
      Areapools.Mark (M, Instance_Pool.all);
      Subprg_Inst := Make_Instance (Syn_Inst, Get_Info (Imp));

      Synth_Subprogram_Association
        (Subprg_Inst, Syn_Inst, Inter_Chain, Assoc_Chain);

      case Def is
         when Iir_Predefined_Ieee_Numeric_Std_Touns_Nat_Nat_Uns =>
            declare
               Arg : constant Value_Acc := Subprg_Inst.Objects (1);
               Size : constant Value_Acc := Subprg_Inst.Objects (2);
               Arg_Net : Net;
            begin
               if not Is_Const (Size) then
                  Error_Msg_Synth (+Expr, "to_unsigned size must be constant");
                  return Arg;
               else
                  --  FIXME: what if the arg is constant too ?
                  if Is_Const (Arg) then
                     return Eval_To_Unsigned
                       (Arg.Scal, Size.Scal,
                        Get_Value_Type (Syn_Inst, Get_Type (Imp)));
                  else
                     Arg_Net := Get_Net (Arg);
                     return Create_Value_Net
                       (Synth_Uresize (Arg_Net, Uns32 (Size.Scal), Expr),
                        Create_Res_Bound (Arg, Arg_Net));
                  end if;
               end if;
            end;
         when Iir_Predefined_Ieee_Numeric_Std_Toint_Uns_Nat =>
            --  UNSIGNED to Natural.
            declare
               Int_Type : constant Type_Acc :=
                 Get_Value_Type (Syn_Inst,
                                 Vhdl.Std_Package.Integer_Subtype_Definition);
            begin
               return Create_Value_Net
                 (Synth_Uresize (Get_Net (Subprg_Inst.Objects (1)),
                                 Int_Type.W, Expr),
                  Int_Type);
            end;
         when Iir_Predefined_Ieee_Numeric_Std_Resize_Uns_Nat =>
            declare
               V : constant Value_Acc := Subprg_Inst.Objects (1);
               Sz : constant Value_Acc := Subprg_Inst.Objects (2);
               W : Width;
            begin
               if not Is_Const (Sz) then
                  Error_Msg_Synth (+Expr, "size must be constant");
                  return null;
               end if;
               W := Uns32 (Sz.Scal);
               return Create_Value_Net
                 (Synth_Uresize (Get_Net (V), W, Expr),
                  Create_Vec_Type_By_Length (W, Logic_Type));
            end;
         when Iir_Predefined_Ieee_Numeric_Std_Resize_Sgn_Nat =>
            declare
               V : constant Value_Acc := Subprg_Inst.Objects (1);
               Sz : constant Value_Acc := Subprg_Inst.Objects (2);
               W : Width;
            begin
               if not Is_Const (Sz) then
                  Error_Msg_Synth (+Expr, "size must be constant");
                  return null;
               end if;
               W := Uns32 (Sz.Scal);
               return Create_Value_Net
                 (Synth_Sresize (Get_Net (V), W, Expr),
                  Create_Vec_Type_By_Length (W, Logic_Type));
            end;
         when Iir_Predefined_Ieee_Numeric_Std_Shl_Uns_Nat =>
            declare
               L : constant Value_Acc := Subprg_Inst.Objects (1);
               R : constant Value_Acc := Subprg_Inst.Objects (2);
            begin
               return Synth_Shift (Id_Lsl, L, R, Expr);
            end;
         when Iir_Predefined_Ieee_Numeric_Std_Shr_Uns_Nat =>
            declare
               L : constant Value_Acc := Subprg_Inst.Objects (1);
               R : constant Value_Acc := Subprg_Inst.Objects (2);
            begin
               return Synth_Shift (Id_Lsr, L, R, Expr);
            end;
         when Iir_Predefined_Ieee_Math_Real_Log2 =>
            declare
               V : constant Value_Acc := Subprg_Inst.Objects (1);

               function Log2 (Arg : Fp64) return Fp64;
               pragma Import (C, Log2);
            begin
               if not Is_Float (V) then
                  Error_Msg_Synth
                    (+Expr, "argument must be a float value");
                  return null;
               end if;
               return Create_Value_Float
                 (Log2 (V.Fp), Get_Value_Type (Syn_Inst, Get_Type (Imp)));
            end;
         when Iir_Predefined_Ieee_Math_Real_Ceil =>
            declare
               V : constant Value_Acc := Subprg_Inst.Objects (1);

               function Ceil (Arg : Fp64) return Fp64;
               pragma Import (C, Ceil);
            begin
               if not Is_Float (V) then
                  Error_Msg_Synth
                    (+Expr, "argument must be a float value");
                  return null;
               end if;
               return Create_Value_Float
                 (Ceil (V.Fp), Get_Value_Type (Syn_Inst, Get_Type (Imp)));
            end;
         when others =>
            Error_Msg_Synth
              (+Expr,
               "unhandled function: " & Iir_Predefined_Functions'Image (Def));
      end case;

      Free_Instance (Subprg_Inst);
      Areapools.Release (M, Instance_Pool.all);

      return null;
   end Synth_Predefined_Function_Call;
end Synth.Oper;
