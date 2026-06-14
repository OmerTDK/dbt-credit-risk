{% macro _date_trunc_quarter(col) %}
    {% if target.type == 'bigquery' %}DATE_TRUNC({{ col }}, QUARTER)
    {% else %}date_trunc('quarter', {{ col }}){% endif %}
{% endmacro %}
