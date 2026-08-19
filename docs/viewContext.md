# viewContext

## ON_TEMPER_EPS — serialisation float dust

A snapped note's detune round-trips through `%.14g` serialisation
(`util.serialise` → `tostring`), which does not preserve a double exactly.
The reconstructed value's gap from its step is float dust (~1e-12 cents),
not a real bend. `ON_TEMPER_EPS = 1e-6` is the threshold below which the
gap is cleared so the cell's cents readout is not drawn for in-temper notes.
