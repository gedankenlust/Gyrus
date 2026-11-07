"""Errors shared by the taxonomy layers."""


class TaxonomyQualityError(ValueError):
    """The model output, or the taxonomy built from it, is not usable."""
