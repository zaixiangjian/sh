<?php
declare (strict_types=1);

return [
    'version' => '1.0.9',
    'name' => '易支付',
    'author' => '荔枝',
    'website' => '#',
    'description' => '支持所有易支付协议',
    'options' => [
        'alipay' => '支付宝',
        'wxpay' => '微信',
        'qqpay' => 'QQ钱包',
        'bank' => '网银支付',
        'jdpay' => '京东支付',
        'paypal' => 'PayPal',
        'douyinpay' => '抖音支付',

        // BEpusdt / 加密货币交易类型
        'usdt.trc20' => 'USDT-TRC20',
        'usdc.trc20' => 'USDC-TRC20',
        'tron.trx' => 'TRX',

        'usdt.erc20' => 'USDT-ERC20',
        'usdc.erc20' => 'USDC-ERC20',
        'ethereum.eth' => 'ETH',

        'usdt.bep20' => 'USDT-BEP20',
        'usdc.bep20' => 'USDC-BEP20',
        'bsc.bnb' => 'BNB',

        'usdt.polygon' => 'USDT-Polygon',
        'usdc.polygon' => 'USDC-Polygon',

        'usdt.aptos' => 'USDT-Aptos',
        'usdc.aptos' => 'USDC-Aptos',

        'usdt.solana' => 'USDT-Solana',
        'usdc.solana' => 'USDC-Solana',

        'usdt.xlayer' => 'USDT-X-Layer',
        'usdc.xlayer' => 'USDC-X-Layer',

        'usdt.arbitrum' => 'USDT-Arbitrum-One',
        'usdc.arbitrum' => 'USDC-Arbitrum-One',

        'usdc.base' => 'USDC-Base',
        'usdt.plasma' => 'USDT-Plasma',
        'usdt.ton' => 'USDT-TON',
        'ton.gram' => 'TON'
    ],
    'callback' => [
        \App\Consts\Pay::IS_SIGN => true,
        \App\Consts\Pay::IS_STATUS => true,
        \App\Consts\Pay::FIELD_STATUS_KEY => 'trade_status',
        \App\Consts\Pay::FIELD_STATUS_VALUE => 'TRADE_SUCCESS',
        \App\Consts\Pay::FIELD_ORDER_KEY => 'out_trade_no',
        \App\Consts\Pay::FIELD_AMOUNT_KEY => 'money',
        \App\Consts\Pay::FIELD_RESPONSE => 'success'
    ]
];
