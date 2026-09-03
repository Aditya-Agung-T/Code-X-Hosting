<div>
    <x-slot:title>
        {{ $title }} | Code X Hosting
    </x-slot>

    <livewire:server.create :selected-type="$type" :selected-token-uuid="$token_uuid" />
</div>
