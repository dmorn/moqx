defmodule MOQXTest do
  use ExUnit.Case

  test "NIF module loads" do
    assert is_function(&MOQX.Native.connect/1)
    assert is_function(&MOQX.Native.session_version/1)
    assert is_function(&MOQX.Native.session_close/1)
  end

  test "connect returns error for invalid URL" do
    assert {:error, _reason} = MOQX.Native.connect(":::invalid")
  end

  test "connect returns ok for valid URL (async)" do
    assert :ok = MOQX.Native.connect("https://localhost:4443")
  end
end
