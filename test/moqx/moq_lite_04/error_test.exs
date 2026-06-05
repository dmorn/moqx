defmodule MOQX.MOQLite04.ErrorTest do
  use ExUnit.Case, async: true

  alias MOQX.MOQLite04.Error

  describe "new/2" do
    test "builds structured local errors with stable transport codes" do
      assert %Error{
               reason: :protocol_violation,
               code: 15,
               source: :local,
               details: %{stream_type: :announce}
             } = Error.new(:protocol_violation, details: %{stream_type: :announce})
    end

    test "maps application-specific errors into the reserved application range" do
      assert %Error{
               reason: :application,
               code: 71,
               source: :local,
               details: %{application_code: 7}
             } = Error.new({:application, 7})
    end

    test "rejects unknown local reasons" do
      assert {:error, {:unknown_error_reason, :missing}} = Error.code(:missing)
    end
  end

  describe "code/1" do
    test "accepts an error struct or known reason" do
      error = Error.new(:unexpected_stream)

      assert Error.code(error) == {:ok, 10}
      assert Error.code(:unexpected_stream) == {:ok, 10}
    end
  end

  describe "from_code/1" do
    test "decodes known protocol codes" do
      assert %Error{reason: :not_found, code: 13, source: :remote} = Error.from_code(13)
    end

    test "decodes application-specific codes without losing the original code" do
      assert %Error{
               reason: :application,
               code: 66,
               source: :remote,
               details: %{application_code: 2}
             } = Error.from_code(66)
    end

    test "preserves unknown peer codes as remote errors" do
      assert %Error{reason: :remote, code: 63, source: :remote} = Error.from_code(63)
    end
  end
end
