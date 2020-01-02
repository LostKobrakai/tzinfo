defmodule Tzinfo.PosixTest do
  use ExUnit.Case, async: true
  import Tzinfo.Posix
  doctest Tzinfo.Posix

  describe "only STD" do
    test "simple" do
      assert {:ok, data} = parse("HST10")
      assert %{std: %{abbr: "HST", utc_offset: 36000, std_offset: 0}, dst: :none} = data
    end

    test "negative" do
      assert {:ok, data} = parse("HST-10")
      assert %{std: %{abbr: "HST", utc_offset: -36000, std_offset: 0}, dst: :none} = data
    end

    test "quoted name" do
      assert {:ok, data} = parse("<-10>-10")
      assert %{std: %{abbr: "-10", utc_offset: -36000, std_offset: 0}, dst: :none} = data
    end
  end

  describe "with DST" do
    test "smallest possible format" do
      assert {:ok, data} = parse("HST10HDT")

      assert %{
               std: %{abbr: "HST", utc_offset: 36000, std_offset: 0},
               dst: %{
                 abbr: "HDT",
                 utc_offset: 36000,
                 std_offset: 3600,
                 start: :undefined,
                 end: :undefined
               }
             } = data
    end

    test "quoted name" do
      assert {:ok, data} = parse("<10>10<11>")

      assert %{
               std: %{abbr: "10", utc_offset: 36000, std_offset: 0},
               dst: %{
                 abbr: "11",
                 utc_offset: 36000,
                 std_offset: 3600,
                 start: :undefined,
                 end: :undefined
               }
             } = data
    end

    test "custom std_offset" do
      assert {:ok, data} = parse("HST10HDT9")

      assert %{
               std: %{abbr: "HST", utc_offset: 36000, std_offset: 0},
               dst: %{
                 abbr: "HDT",
                 utc_offset: 36000,
                 std_offset: -3600,
                 start: :undefined,
                 end: :undefined
               }
             } = data
    end

    test "custom std_offset advanced" do
      assert {:ok, data} = parse("HST10HDT-10:30")

      assert %{
               std: %{abbr: "HST", utc_offset: 36000, std_offset: 0},
               dst: %{
                 abbr: "HDT",
                 utc_offset: 36000,
                 std_offset: -73800,
                 start: :undefined,
                 end: :undefined
               }
             } = data
    end

    test "with start end julian one base" do
      assert {:ok, data} = parse("HST10HDT,J1,J300")

      assert %{
               std: %{abbr: "HST", utc_offset: 36000, std_offset: 0},
               dst: %{
                 abbr: "HDT",
                 utc_offset: 36000,
                 std_offset: 3600,
                 start: %{
                   midnight_offset: 7200,
                   type: :julian_one_based,
                   value: 1
                 },
                 end: %{
                   midnight_offset: 7200,
                   type: :julian_one_based,
                   value: 300
                 }
               }
             } = data
    end

    test "with start end julian zero base" do
      assert {:ok, data} = parse("HST10HDT,0,300")

      assert %{
               std: %{abbr: "HST", utc_offset: 36000, std_offset: 0},
               dst: %{
                 abbr: "HDT",
                 utc_offset: 36000,
                 std_offset: 3600,
                 start: %{
                   midnight_offset: 7200,
                   type: :julian_zero_based,
                   value: 0
                 },
                 end: %{
                   midnight_offset: 7200,
                   type: :julian_zero_based,
                   value: 300
                 }
               }
             } = data
    end

    test "with start end month base" do
      assert {:ok, data} = parse("HST10HDT,M3.5.0,M10.5.0")

      assert %{
               std: %{abbr: "HST", utc_offset: 36000, std_offset: 0},
               dst: %{
                 abbr: "HDT",
                 utc_offset: 36000,
                 std_offset: 3600,
                 start: %{
                   midnight_offset: 7200,
                   type: :month_based,
                   value: %{month: 3, week: 5, day: 0}
                 },
                 end: %{
                   midnight_offset: 7200,
                   type: :month_based,
                   value: %{month: 10, week: 5, day: 0}
                 }
               }
             } = data
    end
  end

  describe "extended offset" do
    test "negative" do
      assert {:ok, data} =
               parse("<-03>3<-02>,M3.5.0/-1,M10.5.0/-2", extended_transition_offset: true)

      assert %{
               std: %{abbr: "-03", utc_offset: 10800, std_offset: 0},
               dst: %{
                 abbr: "-02",
                 utc_offset: 10800,
                 std_offset: 3600,
                 start: %{
                   midnight_offset: -3600,
                   type: :month_based,
                   value: %{month: 3, week: 5, day: 0}
                 },
                 end: %{
                   midnight_offset: -7200,
                   type: :month_based,
                   value: %{month: 10, week: 5, day: 0}
                 }
               }
             } = data
    end

    test "high value" do
      assert {:ok, data} =
               parse("<-03>3<-02>,M3.5.0/-167,M10.5.0/-2", extended_transition_offset: true)

      assert %{
               std: %{abbr: "-03", utc_offset: 10800, std_offset: 0},
               dst: %{
                 abbr: "-02",
                 utc_offset: 10800,
                 std_offset: 3600,
                 start: %{
                   midnight_offset: -601_200,
                   type: :month_based,
                   value: %{month: 3, week: 5, day: 0}
                 },
                 end: %{
                   midnight_offset: -7200,
                   type: :month_based,
                   value: %{month: 10, week: 5, day: 0}
                 }
               }
             } = data
    end

    test "error" do
      assert {:error, _} = parse("<-03>3<-02>,M3.5.0/-1,M10.5.0/-2")
    end
  end

  describe "dst all year" do
    test "success" do
      assert {:ok, data} =
               parse("EST5EDT,0/0,J365/25", extended_transition_offset: true, all_year_dst: true)

      assert %{
               std: :none,
               dst: %{
                 abbr: "EDT",
                 utc_offset: 18000,
                 std_offset: 3600,
                 start: %{
                   midnight_offset: 0,
                   type: :julian_zero_based,
                   value: 0
                 },
                 end: %{
                   midnight_offset: 90000,
                   type: :julian_one_based,
                   value: 365
                 }
               }
             } = data
    end

    test "no success" do
      assert {:ok, data} =
               parse("EST5EDT,0/0,J365/24:59:59",
                 extended_transition_offset: true,
                 all_year_dst: true
               )

      refute :none == data.std
    end

    test "disabled" do
      assert {:ok, data} =
               parse("EST5EDT,0/0,J365/25",
                 extended_transition_offset: true,
                 all_year_dst: false
               )

      refute :none == data.std
    end
  end
end
