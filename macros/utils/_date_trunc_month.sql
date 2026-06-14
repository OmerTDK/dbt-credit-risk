{% macro _date_trunc_month(col) %}
    {% if target.type == 'bigquery' %}DATE_TRUNC({{ col }}, MONTH)
    {% else %}date_trunc('month', {{ col }}){% endif %}
{% endmacro %}
