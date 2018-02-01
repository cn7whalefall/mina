open Core_kernel

module type Basic = sig
  type t

  val fold : t -> init:'a -> f:('a -> bool -> 'a) -> 'a
end

module type S = sig
  include Basic

  val iter : t -> f:(bool -> unit) -> unit
  val to_bits : t -> bool list
end

module type Snarkable = sig
  type (_, _) var_spec
  type (_, _) checked
  type boolean_var

  module Packed : sig
    type var
    type value
    val spec : (var, value) var_spec
  end

  type var
  type value

  val spec : (var, value) var_spec

  val packed : var -> Packed.var
  val to_bits : var -> boolean_var list

  (* TODO: Delete
  module Unpacked : sig
    type var
    type value

    include S with type t := value

    val spec : (var, value) var_spec

    val to_bits : var -> boolean_var list
  end

  module Checked : sig
    val unpack : Packed.var -> (Unpacked.var, _) checked
  end

  val unpack : Packed.value -> Unpacked.value *)
end
