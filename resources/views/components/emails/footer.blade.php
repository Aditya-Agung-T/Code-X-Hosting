{{ Illuminate\Mail\Markdown::parse('---') }}

Thank you,<br>
{{ config('app.name') ?? 'Code X Hosting' }}

{{ Illuminate\Mail\Markdown::parse('[Contact Support](https://coolify.io/docs/contact)') }}
