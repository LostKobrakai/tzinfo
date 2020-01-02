defmodule Tzinfo.ParserTest do
  use ExUnit.Case

  test "golden master" do
    contents = File.read!("test/fixtures/EuropeBerlin")
    assert {:ok, data} = Tzinfo.Parser.parse(contents)

    assert %{
             bin: "",
             version: 2,
             data: %{
               designations: %{
                 0 => "LMT",
                 4 => "CEST",
                 9 => "CET",
                 13 => "CEMT"
               },
               leap_seconds: [],
               std_wall_indicators: [0, 0, 0, 1, 1, 0, 1, 1, 1],
               transition_types: transition_types,
               transitions: transitions,
               types: [
                 %{designation_index: 0, dst: false, offset: 3208},
                 %{designation_index: 4, dst: true, offset: 7200},
                 %{designation_index: 9, dst: false, offset: 3600},
                 %{designation_index: 4, dst: true, offset: 7200},
                 %{designation_index: 9, dst: false, offset: 3600},
                 %{designation_index: 13, dst: true, offset: 10800},
                 %{designation_index: 13, dst: true, offset: 10800},
                 %{designation_index: 4, dst: true, offset: 7200},
                 %{designation_index: 9, dst: false, offset: 3600}
               ],
               ut_local_indicators: [0, 0, 0, 0, 0, 0, 0, 1, 1]
             },
             footer: "CET-1CEST,M3.5.0,M10.5.0/3"
           } = data

    assert length(transitions) == 145
    assert length(transition_types) == 145
  end

  describe "rfc examples" do
    test "example 1" do
      contents = rfc_example_to_binary("test/fixtures/rfc_example_1.txt")

      assert {:ok, data} = Tzinfo.Parser.parse(contents)

      assert %{
               bin: "",
               version: 1,
               data: %{
                 designations: %{
                   0 => "UTC"
                 },
                 leap_seconds: [
                   {78_796_800, 1},
                   {94_694_401, 2},
                   {126_230_402, 3},
                   {157_766_403, 4},
                   {189_302_404, 5},
                   {220_924_805, 6},
                   {252_460_806, 7},
                   {283_996_807, 8},
                   {315_532_808, 9},
                   {362_793_609, 10},
                   {394_329_610, 11},
                   {425_865_611, 12},
                   {489_024_012, 13},
                   {567_993_613, 14},
                   {631_152_014, 15},
                   {662_688_015, 16},
                   {709_948_816, 17},
                   {741_484_817, 18},
                   {773_020_818, 19},
                   {820_454_419, 20},
                   {867_715_220, 21},
                   {915_148_821, 22},
                   {1_136_073_622, 23},
                   {1_230_768_023, 24},
                   {1_341_100_824, 25},
                   {1_435_708_825, 26},
                   {1_483_228_826, 27}
                 ],
                 std_wall_indicators: [0],
                 transition_types: [],
                 transitions: [],
                 types: [
                   %{designation_index: 0, dst: false, offset: 0}
                 ],
                 ut_local_indicators: [0]
               },
               footer: :not_included
             } = data
    end

    test "example 2" do
      contents = rfc_example_to_binary("test/fixtures/rfc_example_2.txt")

      assert {:ok, data} = Tzinfo.Parser.parse(contents)

      assert %{
               bin: "",
               version: 2,
               data: %{
                 designations: %{
                   0 => "LMT",
                   4 => "HST",
                   8 => "HDT",
                   12 => "HWT",
                   16 => "HPT"
                 },
                 leap_seconds: [],
                 std_wall_indicators: [0, 0, 0, 0, 1, 0],
                 transition_types: [1, 2, 1, 3, 4, 1, 5],
                 transitions: [
                   -2_334_101_314,
                   -1_157_283_000,
                   -1_155_436_200,
                   -880_198_200,
                   -769_395_600,
                   -765_376_200,
                   -712_150_200
                 ],
                 types: [
                   %{designation_index: 0, dst: false, offset: -37886},
                   %{designation_index: 4, dst: false, offset: -37800},
                   %{designation_index: 8, dst: true, offset: -34200},
                   %{designation_index: 12, dst: true, offset: -34200},
                   %{designation_index: 16, dst: true, offset: -34200},
                   %{designation_index: 4, dst: false, offset: -36000}
                 ],
                 ut_local_indicators: [0, 0, 0, 0, 1, 0]
               },
               footer: "HST10"
             } = data
    end

    test "example 3" do
      contents = rfc_example_to_binary("test/fixtures/rfc_example_3.txt")

      assert {:ok, data} = Tzinfo.Parser.parse(contents)

      assert %{
               bin: "",
               version: 3,
               data: %{
                 designations: %{
                   0 => "IST"
                 },
                 leap_seconds: [],
                 std_wall_indicators: [1],
                 transition_types: [0],
                 transitions: [2_145_916_800],
                 types: [
                   %{designation_index: 0, dst: false, offset: 7200}
                 ],
                 ut_local_indicators: [1]
               },
               footer: "IST-2IDT,M3.4.4/26,M10.5.0"
             } = data
    end
  end

  defp rfc_example_to_binary(path) do
    pattern = ~r/^\|.*?\| ([a-f0-9 ]*?) *?\|.*?\|.*?\|$/

    path
    |> File.stream!()
    |> Enum.map(fn line ->
      line = String.trim(line)

      case Regex.run(pattern, line) do
        [^line, ""] -> nil
        [^line, binary] -> binary
        _ -> nil
      end
    end)
    |> Enum.filter(& &1)
    |> Enum.flat_map(&String.split(&1, " "))
    |> Enum.map(fn hex ->
      {hex, ""} = Integer.parse(hex, 16)
      <<hex::integer-size(1)-unit(8)>>
    end)
    |> IO.iodata_to_binary()
  end
end
