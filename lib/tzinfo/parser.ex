defmodule Tzinfo.Parser do
  @moduledoc """
  Parser for TZif files (V1, V2, V3)

  See https://tools.ietf.org/html/rfc8536
  """
  @type t :: %__MODULE__{
          bin: binary(),
          version: 1 | 2 | 3,
          counters: %{
            optional(counter_key) => integer()
          },
          data: %{
            optional(:transitions) => [integer()],
            optional(:transition_types) => [integer()],
            optional(:types) => [
              %{
                dst: boolean(),
                offset: integer(),
                designation_index: non_neg_integer()
              }
            ],
            optional(:designations) => %{
              optional(start_index :: integer) => String.t()
            }
          }
        }

  @type counter_key :: :isut | :isstd | :leap | :time | :type | :char
  @type data_key ::
          :transitions
          | :transition_types
          | :types
          | :designations
          | :leap_seconds
          | :std_wall_indicators
          | :ut_local_indicators

  defstruct bin: nil, version: nil, counters: %{}, data: %{}, footer: nil

  @doc """
  Parse the binary contents of a TZif file.
  """
  def parse(contents) do
    token = %__MODULE__{bin: contents}

    with {:ok, token} <- parse_header(token),
         {:ok, token} <- maybe_skip_version_1_data(token),
         {:ok, token} <- parse_data_block(token),
         {:ok, token} <- parse_footer(token) do
      {:ok, token |> Map.from_struct() |> Map.drop([])}
    end
  end

  # +---------------+---+
  # |  magic    (4) |ver|
  # +---------------+---+---------------------------------------+
  # |           [unused - reserved for future use] (15)         |
  # +---------------+---------------+---------------+-----------+
  # |  isutcnt  (4) |  isstdcnt (4) |  leapcnt  (4) |
  # +---------------+---------------+---------------+
  # |  timecnt  (4) |  typecnt  (4) |  charcnt  (4) |
  # +---------------+---------------+---------------+
  #
  #                          TZif Header
  defp parse_header(token, type \\ 32) do
    case token.bin do
      <<"TZif", version::binary-size(1), reserved::15*8,
        isutcnt::unsigned-big-integer-size(4)-unit(8),
        isstdcnt::unsigned-big-integer-size(4)-unit(8),
        leapcnt::unsigned-big-integer-size(4)-unit(8),
        timecnt::unsigned-big-integer-size(4)-unit(8),
        typecnt::unsigned-big-integer-size(4)-unit(8),
        charcnt::unsigned-big-integer-size(4)-unit(8), rest::binary>>
      when version in [<<0>>, "2", "3"] and
             reserved == 0 and
             (isutcnt == 0 or isutcnt == typecnt) and
             (isstdcnt == 0 or isutcnt == typecnt) and
             (charcnt != 0 or (version in ["2", "3"] and type == 32)) ->
        counters = %{
          isut: isutcnt,
          isstd: isstdcnt,
          leap: leapcnt,
          time: timecnt,
          type: typecnt,
          char: charcnt
        }

        {:ok, %{token | version: normalize_version(version), counters: counters, bin: rest}}

      _ ->
        {:error, {:parsing, :header, type}}
    end
  end

  defp normalize_version(<<0>>), do: 1
  defp normalize_version("2"), do: 2
  defp normalize_version("3"), do: 3

  # When reading a version 2 or 3 file, implementations SHOULD ignore
  # the version 1 header and data block except for the purpose of
  # skipping over them.
  defp maybe_skip_version_1_data(%{version: version} = token) when version != 1 do
    to_skip = token.counters |> data_block_sizes(1) |> Enum.sum()
    <<_::binary-size(to_skip)-unit(8), rest::binary>> = token.bin

    with {:ok, token} <- parse_header(%{token | bin: rest}, 64) do
      {:ok, token}
    end
  end

  defp maybe_skip_version_1_data(token), do: {:ok, token}

  # +---------------------------------------------------------+
  # |  transition times          (timecnt x TIME_SIZE)        |
  # +---------------------------------------------------------+
  # |  transition types          (timecnt)                    |
  # +---------------------------------------------------------+
  # |  local time type records   (typecnt x 6)                |
  # +---------------------------------------------------------+
  # |  time zone designations    (charcnt)                    |
  # +---------------------------------------------------------+
  # |  leap-second records       (leapcnt x (TIME_SIZE + 4))  |
  # +---------------------------------------------------------+
  # |  standard/wall indicators  (isstdcnt)                   |
  # +---------------------------------------------------------+
  # |  UT/local indicators       (isutcnt)                    |
  # +---------------------------------------------------------+
  #
  #                       TZif Data Block
  defp parse_data_block(token) do
    [
      transitions_size,
      transition_types_size,
      types_size,
      designation_size,
      leap_seconds_size,
      std_wall_indicators_size,
      ut_local_indicators_size
    ] = data_block_sizes(token.counters, token.version)

    case token.bin do
      <<transitions::binary-size(transitions_size),
        transition_types::binary-size(transition_types_size), types::binary-size(types_size),
        designations::binary-size(designation_size), leap_seconds::binary-size(leap_seconds_size),
        std_wall_indicators::binary-size(std_wall_indicators_size),
        ut_local_indicators::binary-size(ut_local_indicators_size), rest::binary>> ->
        data = %{
          transitions: parse_transitions(transitions, time_size(token.version)),
          transition_types: parse_transition_types(transition_types),
          types: parse_types(types),
          designations: parse_designations(designations),
          leap_seconds: parse_leap_seconds(leap_seconds, time_size(token.version)),
          std_wall_indicators: parse_std_wall_indicators(std_wall_indicators),
          ut_local_indicators: parse_ut_local_indicators(ut_local_indicators)
        }

        with :ok <- validate_same_length_transitions_and_transition_types(data),
             :ok <- validate_indicators_invariant(data) do
          {:ok, %{token | data: data, bin: rest}}
        end

      _ ->
        {:error, {:parsing, :data_block}}
    end
  end

  defp data_block_sizes(counters, version) do
    [
      counters.time * time_size(version),
      counters.time,
      counters.type * 6,
      counters.char,
      counters.leap * (time_size(version) + 4),
      counters.isstd,
      counters.isut
    ]
  end

  # In the version 1 data block, time values are 32 bits (TIME_SIZE = 4
  # octets).  In the version 2+ data block, present only in version 2 and
  # 3 files, time values are 64 bits (TIME_SIZE = 8 octets).
  defp time_size(1), do: 4
  defp time_size(2), do: 8
  defp time_size(3), do: 8

  # Each time value SHOULD be at least -2**59.
  #     (-2**59 is the greatest negated power of 2 that predates the Big
  #     Bang, and avoiding earlier timestamps works around known TZif
  #     reader bugs relating to outlandishly negative timestamps.)
  @before_big_bang -576_460_752_303_423_500

  defp parse_transitions(transitions, size) do
    continously_match(transitions, fn
      "" ->
        nil

      <<value::signed-big-integer-size(size)-unit(8), rest::binary>>
      when value >= @before_big_bang ->
        {value, rest}
    end)
  end

  defp parse_transition_types(transition_types) do
    continously_match(transition_types, fn
      "" -> nil
      <<value::signed-big-integer-size(1)-unit(8), rest::binary>> when value >= 0 -> {value, rest}
    end)
  end

  defp parse_types(types) do
    continously_match(types, fn
      "" ->
        nil

      <<utoffset::signed-big-integer-size(4)-unit(8), isdst::integer, designation_index::integer,
        rest::binary>>
      when isdst in [0, 1] and designation_index >= 0 ->
        {%{offset: utoffset, dst: isdst == 1, designation_index: designation_index}, rest}
    end)
  end

  defp parse_designations(designations) do
    {names, _} =
      designations
      |> :binary.split([<<0>>], [:global, :trim])
      |> Enum.map_reduce(0, fn name, acc ->
        {{acc, name}, acc + 1 + byte_size(name)}
      end)

    Map.new(names)
  end

  defp parse_leap_seconds(leap_seconds, size) do
    continously_match(leap_seconds, fn
      "" ->
        nil

      <<first_value::big-integer-size(size)-unit(8), second_value::big-integer-size(4)-unit(8),
        rest::binary>> ->
        {{first_value, second_value}, rest}
    end)
  end

  defp parse_std_wall_indicators(std_wall_indicators) do
    parse_toggle(std_wall_indicators)
  end

  defp parse_ut_local_indicators(ut_local_indicators) do
    parse_toggle(ut_local_indicators)
  end

  defp parse_toggle(toggles) do
    continously_match(toggles, fn
      "" -> nil
      <<toggle::integer-size(1)-unit(8), rest::binary>> when toggle in [0, 1] -> {toggle, rest}
    end)
  end

  defp continously_match(binary, matcher) do
    binary
    |> Stream.unfold(matcher)
    |> Enum.into([])
  end

  defp validate_same_length_transitions_and_transition_types(data) do
    if Enum.count(data.transitions) == Enum.count(data.transition_types) do
      :ok
    else
      {:error, {:validation, :transitions_and_transition_types_length}}
    end
  end

  defp validate_indicators_invariant(data) do
    pairs = Enum.zip(data.std_wall_indicators, data.ut_local_indicators)

    if Enum.all?(pairs, &(&1 in [{1, 1}, {1, 0}, {0, 0}])) do
      :ok
    else
      {:error, {:validation, :indicators_invariant}}
    end
  end

  defp parse_footer(%{version: 1} = token) do
    {:ok, %{token | footer: :not_included}}
  end

  defp parse_footer(token) do
    case token.bin do
      <<"\n", rest::binary>> ->
        case :binary.split(rest, ["\n"]) do
          [footer, rest] -> {:ok, %{token | footer: footer, bin: rest}}
          _ -> {:error, {:parsing, :footer}}
        end

      _ ->
        {:error, {:parsing, :footer}}
    end
  end
end
